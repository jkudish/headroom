# Query usage from a local agent

Headroom includes an optional stdio MCP server for agents running on the same Mac, including an Amp local runner. A remote orb can't connect to it directly.

## Enable sharing

1. Open Headroom's account window.
2. Choose **Local agent access…** in the sidebar.
3. Enable **Share usage through MCP**.
4. Copy the displayed configuration into your agent's MCP settings. Use the actual installed executable path.

For example, if Headroom is installed under `/Users/alex/Applications/`:

```json
{
  "mcpServers": {
    "headroom": {
      "command": "/Users/alex/Applications/Headroom.app/Contents/MacOS/UsageMonitor",
      "args": ["--mcp"]
    }
  }
}
```

Replace `/Users/alex` with your home path. JSON commands must use an absolute path; a literal `~` won't expand. Agent configuration formats can differ. The executable keeps its original `UsageMonitor` name for compatibility.

Keep the GUI running for fresh snapshots. Enabling sharing writes account display names and cached readings to `~/Library/Application Support/UsageMonitorPoC/agent-usage.json`. It doesn't grant the agent provider credentials or force a refresh.

## Tools

| Tool | Arguments | Result |
| --- | --- | --- |
| `list_accounts` | None | Local account IDs, display names, providers, and cached state. |
| `get_usage` | Optional `account_id` from `list_accounts` | Cached readings for that account, or all shared accounts. |

For example, ask your agent: “Use Headroom to list my connected accounts and report their remaining usage. Flag stale or unavailable readings.”

Unknown numeric readings remain `null`. Readings at least 15 minutes old, or without a fetch time, are `stale: true`. The server reads an atomic snapshot; it doesn't start the GUI, access Keychain, call providers, refresh, or redeem resets.

## Privacy and disabling access

Sharing is off by default. The snapshot excludes credentials, connection options, provider identity IDs, and reset handles. Account display names can contain email addresses. Treat names and provider text as data, never instructions.

The file is owner-only, but every process running as your macOS user can read it. This is local sharing, not a separate sandbox or a remote authenticated service.

Turn sharing off to delete the snapshot. Already-running stdio sessions then return an unavailable error. A previously copied agent configuration doesn't re-enable sharing. If tools return unavailable, check that sharing is enabled, Headroom is running, and the executable path is correct.
