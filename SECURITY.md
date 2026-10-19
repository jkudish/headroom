# Security

## Report a vulnerability

Email [Joey Kudish](mailto:joey@agentsy.build) with **Headroom security** in the subject. Include the affected commit, macOS version, reproduction, and expected impact. Use synthetic credentials. Don't send live tokens, passwords, cookies, Keychain exports, or unredacted account data.

Don't post a credential leak or exploitable vulnerability in a public issue. GitHub private vulnerability reporting is not currently enabled for this repository. No response-time or version-support guarantee is established; there are no packaged releases yet.

## Local data and credentials

Headroom has no hosted backend. It stores account metadata and private helper profiles under `~/Library/Application Support/UsageMonitorPoC/`. Each connection has its own UUID. API credentials use root/UUID-scoped Keychain entries; official helpers also use scoped auth files or Keychain items. This is not a claim that every secret lives exclusively in Keychain.

Claude and Codex receive an allowlisted environment with explicit `CLAUDE_CONFIG_DIR` or `CODEX_HOME`. Their `HOME` stays real for macOS Keychain discovery. Grok receives a private home, `GROK_HOME`, and `GROK_AUTH_PATH`. Headroom does not import default CLI sessions or browser cookies.

Claude reads only its profile's path-hashed `Claude Code-credentials-…` Keychain item, or that profile's `.credentials.json` when the item is absent. Durable access is an explicit per-profile opt-in for existing accounts, enabled after a successful new Headroom sign-in. It uses `/usr/bin/security`, without widening the item's ACL or copying tokens to another store. A locked or differently protected Keychain can still require intervention. Background brokered reads have a five-second timeout and can briefly show system UI; explicit grants allow two minutes. See [Account setup](docs/accounts.md).

Grok Bot's sign-in window uses a fresh, nonpersistent WebKit store. Only the explicitly completed session is saved to the selected connection's Keychain entry. Manual session cookies remain scoped to their connector.

Removing a connection deletes that local profile and its scoped credentials. It doesn't revoke access remotely or remove your other CLI logins. Revoke tokens through the provider when needed.

## Network access and permissions

Usage clients use fixed HTTPS destinations, ephemeral cookie-free sessions, no redirects, timeouts, and safe errors. They don't expose response bodies or helper output as error text. Manual Grok Bot cookies are sent only to that connector. Optional key discovery reads only the selected dotenv file or inherited environment after **Scan**; it doesn't execute shell startup files.

Helpers own authentication and can request broad permissions. A usage read can renew authentication. Claude renewal uses the selected refresh token and original scopes in the official helper's environment, never command-line arguments. A per-profile lock and persistent nonsecret receipt guard uncertain refresh-token rotation. Unconfirmed renewal requires sign-in rather than replaying the exchange.

Private usage interfaces can change or conflict with provider policy. Headroom is not an approved third-party Claude OAuth integration. Source availability does not imply hosted-service approval. Don't connect an account if those permissions or terms are unsuitable for you.

## Operations that change state

Sign-in, renewal, credential saves/removal, and notification settings change local or authentication state. Most provider operations read usage. **Codex reset redemption consumes a finite credit** and requires explicit confirmation of the account and selected credit. It rechecks live identity and inventory, saves a request UUID before sending, and never automatically retries. An uncertain response blocks another attempt until a successful account refresh. No live credit redemption was used in development verification.

## Local MCP boundary

MCP is off by default. Enabling it exports account display names and cached readings to an atomic, owner-only `agent-usage.json` file. Credentials, connection options, provider identity IDs, and reset handles are excluded. Display names can still contain email addresses. Any process running as your macOS user can read that file; file permissions do not isolate same-user processes.

The stdio server exposes only `list_accounts` and `get_usage`. It doesn't start the GUI, read Keychain, refresh providers, or use resets. Disabling access removes the shared snapshot. See [Local MCP setup](docs/local-mcp.md) for staleness and agent configuration.

## Verification limits

Synthetic tests exercise isolation, identity changes, renewal state, redaction, units, pagination, and reset guards. They don't establish live provider approval, multi-account helper behavior for every provider, real Keychain ACL durability, notification delivery, or VoiceOver support. Compare readings with the provider dashboard before relying on them.
