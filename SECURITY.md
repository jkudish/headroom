# Security

## Report a vulnerability

Email [joey@agentsy.build](mailto:joey@agentsy.build) with **Headroom security** in the subject. Include the affected version or commit, macOS version, reproduction steps, and impact.

Use synthetic credentials. Don't send live keys, tokens, cookies, or private account data. Report vulnerabilities privately, not through public issues. There is no guaranteed response time.

## Security boundaries

- Credentials are stored locally in Keychain or isolated helper profiles. Removing an account doesn't revoke its tokens with the provider.
- Official sign-in helpers can request broad permissions. Private provider interfaces can break or conflict with provider policy.
- Local MCP is off by default. When enabled, other processes running as your macOS user can read shared account names and cached usage, but no credentials.
- Codex reset redemption consumes a finite credit and requires confirmation. Uncertain Claude token renewal requires reconnection.

See [account setup](docs/accounts.md), [reset credits](docs/reset-credits.md), and [local MCP](docs/local-mcp.md) for details.
