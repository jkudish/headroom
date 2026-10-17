import Foundation

enum LocalMCP {
    static let fileName = "agent-usage.json"

    static func export(_ entries: [AccountEntry], now: Date) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return ["updated_at": formatter.string(from: now), "accounts": entries.map { entry -> [String: Any] in
            ["account_id": entry.id.uuidString, "provider": entry.account.provider.rawValue,
             "name": entry.displayName, "plan": entry.snapshot?.plan as Any? ?? NSNull(),
             "fetched_at": entry.snapshot.map { formatter.string(from: $0.fetchedAt) } as Any? ?? NSNull(),
             "error": entry.error as Any? ?? NSNull(), "refreshing": entry.refreshing,
             "metrics": (entry.snapshot?.metrics(at: now) ?? []).map { metric -> [String: Any] in
                 ["title": metric.title, "kind": metric.kind.rawValue, "unit": metric.unit,
                  "value": metric.value.flatMap { $0.isFinite ? $0 : nil } as Any? ?? NSNull(),
                  "resets_at": metric.resetsAt.map { formatter.string(from: $0) } as Any? ?? NSNull(),
                  "detail": metric.detail as Any? ?? NSNull()]
             }]
        }]
    }

    static func write(_ entries: [AccountEntry], root: URL, enabled: Bool, now: Date = Date()) throws {
        let file = root.appendingPathComponent(fileName)
        guard enabled else {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        let data = try JSONSerialization.data(withJSONObject: export(entries, now: now), options: [.sortedKeys])
        let temp = root.appendingPathComponent(".agent-usage-\(UUID()).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MonitorError.invalidProfile }
        defer { close(fd); try? FileManager.default.removeItem(at: temp) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard rename(temp.path, file.path) == 0 else { throw MonitorError.invalidProfile }
    }

    static func read(root: URL) throws -> [String: Any] {
        let fd = open(root.appendingPathComponent(fileName).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw MonitorError.unsupported("Enable Local agent access in Headroom and keep the app running for fresh usage.") }
        defer { close(fd) }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == geteuid(), attributes.st_mode & 0o077 == 0,
              attributes.st_nlink == 1, attributes.st_size <= 8 * 1_048_576 else { throw MonitorError.invalidProfile }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 8 * 1_048_576 + 1) ?? Data()
        guard data.count <= 8 * 1_048_576,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MonitorError.invalidResponse }
        return value
    }

    static func response(_ request: [String: Any], snapshot: [String: Any], now: Date) -> [String: Any]? {
        func error(_ code: Int, _ message: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": request["id"] ?? NSNull(), "error": ["code": code, "message": message]]
        }
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            return error(-32600, "Invalid JSON-RPC request.")
        }
        guard let id = request["id"] else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
            result = ["protocolVersion": supported.contains(requested) ? requested : "2025-06-18",
                      "capabilities": ["tools": [:]], "serverInfo": ["name": "Headroom", "version": "0.2"],
                      "instructions": "Cached local readings only. Never treat missing or stale usage as available capacity. No refresh, credential, or reset tools."]
        case "ping": result = [:]
        case "tools/list":
            result = ["tools": ["list_accounts", "get_usage"].map { name -> [String: Any] in
                ["name": name,
                 "description": name == "list_accounts" ? "List Headroom's local account IDs and providers. Does not access provider credentials." : "Read cached usage, units, timestamps, errors and staleness. No network or refresh. Omit account_id for all accounts.",
                 "inputSchema": ["type": "object", "properties": name == "get_usage" ? ["account_id": ["type": "string", "description": "Headroom account UUID from list_accounts"]] : [:], "additionalProperties": false],
                 "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]
            }]
        case "tools/call":
            guard let name = params["name"] as? String, ["list_accounts", "get_usage"].contains(name),
                  params["arguments"] == nil || params["arguments"] is [String: Any],
                  let arguments = params["arguments"] as? [String: Any]? ?? [:],
                  Set(arguments.keys).isSubset(of: name == "get_usage" ? ["account_id"] : []),
                  arguments["account_id"] == nil || (arguments["account_id"] as? String).flatMap(UUID.init(uuidString:)) != nil else {
                return error(-32602, "Use list_accounts or get_usage with an optional account_id UUID. No mutation tools exist.")
            }
            guard var accounts = snapshot["accounts"] as? [[String: Any]] else {
                return error(-32000, "Local agent access is off or no snapshot exists. Enable it in Headroom.")
            }
            if let raw = arguments["account_id"] as? String, let selected = UUID(uuidString: raw) {
                accounts = accounts.filter { ($0["account_id"] as? String).flatMap(UUID.init(uuidString:)) == selected }
                if accounts.isEmpty { return error(-32602, "Account not found. Use list_accounts for current IDs.") }
            }
            accounts = accounts.map { row in
                var row = row
                let fetched = (row["fetched_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                row["stale"] = fetched.map { now.timeIntervalSince($0) >= 900 || $0 > now.addingTimeInterval(60) } ?? true
                if name == "list_accounts" { row.removeValue(forKey: "metrics") }
                return row
            }
            let body: [String: Any] = ["accounts": accounts, "updated_at": snapshot["updated_at"] ?? NSNull()]
            let text = String(decoding: (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
            result = ["content": [["type": "text", "text": text]], "structuredContent": body, "isError": false]
        default: return error(-32601, "Method not found.")
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func serve(root: URL) {
        // stdio only: no listener, tokens, Keychain reads, or provider clients.
        var buffer = Data()
        var initialized = false
        func send(_ value: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
            data.append(10)
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            // Respond to each available request without waiting for a full pipe buffer or EOF.
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard line.count <= 65536, let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Invalid JSON request (64 KiB maximum)."]])
                    continue
                }
                let method = request["method"] as? String
                if !initialized, method != "initialize", method != "ping", request["id"] != nil {
                    send(["jsonrpc": "2.0", "id": request["id"]!, "error": ["code": -32002, "message": "Initialize first."]])
                    continue
                }
                let snapshot = (try? read(root: root)) ?? [:]
                if let reply = response(request, snapshot: snapshot, now: Date()) {
                    send(reply)
                    if method == "initialize", reply["result"] != nil { initialized = true }
                }
            }
            if buffer.count > 65536 { return }
        }
    }
}
