import Foundation

enum ScopedCLI {
    static func run(executable: URL, arguments: [String], environment: [String: String], directory: URL,
                    billingRPC: Bool = false, timeout: TimeInterval = 30, notFoundStatus: Int32? = nil) async throws -> Data {
        let child = ChildProcess()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                let process = child.process
                let input = Pipe(), output = Pipe()
                // A helper may close stdin between a reply and our next request.
                guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw MonitorError.helperFailed }
                process.executableURL = executable
                process.arguments = arguments
                process.environment = environment
                process.currentDirectoryURL = directory
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try child.start()
                let deadline = DispatchWorkItem { child.stop() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                defer {
                    deadline.cancel()
                    child.stop()
                    try? input.fileHandleForWriting.close()
                    try? output.fileHandleForReading.close()
                }
                func send(_ id: Int, method: String, params: [String: Any]) throws {
                    var data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params], options: [.withoutEscapingSlashes])
                    data.append(10)
                    try input.fileHandleForWriting.write(contentsOf: data)
                }
                if billingRPC {
                    try send(1, method: "initialize", params: ["protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]])
                } else { try input.fileHandleForWriting.close() }
                var bytes = Data(), pending = Data()
                var expected = 1
                var total = 0
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    guard !child.stopped else { throw MonitorError.helperFailed }
                    var ready = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    let available = poll(&ready, 1, 200)
                    if available < 0, errno == EINTR { continue }
                    guard available >= 0 else { throw MonitorError.helperFailed }
                    if available == 0 { continue }
                    // FileHandle.read(upToCount:) can wait to fill its buffer on macOS pipes.
                    let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    guard count >= 0 else { throw MonitorError.helperFailed }
                    if count == 0 { break }
                    let part = Data(buffer.prefix(count))
                    total += part.count
                    guard total <= 1_048_576 else { throw MonitorError.invalidResponse }
                    if !billingRPC { bytes.append(part); continue }
                    pending.append(part)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = pending.prefix(upTo: newline)
                        pending.removeSubrange(...newline)
                        guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                        // No filesystem, terminal, session, or inference requests are serviced.
                        if reply["method"] != nil, reply["id"] != nil { throw MonitorError.invalidResponse }
                        guard reply["id"] as? Int == expected else { continue }
                        guard reply["error"] == nil, let result = reply["result"] as? [String: Any] else { throw MonitorError.signInRequired }
                        if expected == 1 { expected = 2; try send(2, method: "_x.ai/billing", params: [:]) }
                        else {
                            // Let the helper finish credential persistence before the forced-stop fallback.
                            try? input.fileHandleForWriting.close()
                            let end = Date().addingTimeInterval(2)
                            while process.isRunning && !child.stopped && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
                            return try JSONSerialization.data(withJSONObject: result)
                        }
                    }
                }
                process.waitUntilExit()
                if !child.stopped, let notFoundStatus, process.terminationStatus == notFoundStatus {
                    throw MonitorError.signInRequired
                }
                guard !billingRPC, !child.stopped, process.terminationStatus == 0 else { throw MonitorError.helperFailed }
                return bytes
            }.value
        } onCancel: { child.stop() }
    }
}

private final class ChildProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    var stopped: Bool { lock.withLock { cancelled } }

    func start() throws {
        try lock.withLock {
            guard !cancelled else { throw MonitorError.helperFailed }
            do { try process.run() }
            catch { throw MonitorError.helperFailed }
        }
    }

    func stop() {
        lock.withLock {
            cancelled = true
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in
                    if process.isRunning, process.processIdentifier == pid { Darwin.kill(pid, SIGKILL) }
                }
            }
        }
    }
}
