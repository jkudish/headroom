# Connect accounts

Headroom keeps independent connections. You don't need to sign an account into your usual CLI first. Check the [provider reference](providers.md) for the credential type and available readings.

## Claude and Codex

Install the relevant official helper: [Claude Code](https://code.claude.com/docs/en/setup) or [Codex CLI](https://developers.openai.com/codex/cli/). Headroom looks in `~/.local/bin/`, `/opt/homebrew/bin/`, and `/usr/local/bin/`; it doesn't execute an arbitrary helper from your shell's `PATH`. The interfaces were checked with Claude Code 2.1.291 and Codex 0.153.4. Other versions need testing.

1. Select the service in the sidebar and choose **Add account**, or use **Add account…** in the menu.
2. Open the generated sign-in link in the browser profile for that account.
3. For Claude, finish browser approval and paste the authorization code when asked. For Codex, enter the displayed device code on OpenAI's page and wait for approval. If device sign-in is blocked, enable device code authorization in ChatGPT Security settings.
4. Repeat for each account. Each connection gets its own private helper profile.

The helpers request their normal permissions, which are broader than usage-only access. See [Security](../SECURITY.md).

## Grok and Grok Bot

For **Grok / SuperGrok**, choose browser sign-in in the connection form. Install the [official Grok helper](https://github.com/xai-org/grok-build) at `~/.grok/bin/grok`, `/opt/homebrew/bin/grok`, or `/usr/local/bin/grok`. The helper owns OAuth exchange and refresh rotation in an isolated profile. Manual access-token entry remains available, but manual tokens need renewal. An xAI developer API key does not provide a SuperGrok subscription reading.

**Grok Bot** has a separate private sign-in window. It uses Cursor-backed sign-in, not SuperGrok authentication. Embedded SSO can be blocked; manual session Cookie-header entry remains available. Headroom doesn't import cookies from your normal browser. Both Grok sign-in paths are experimental; two-account login/renewal and embedded SSO still need live verification.

## API keys and tokens

Enter credentials in the native connection form. Keep them out of issue reports and agent chats. Billing reads can require an organization Admin or Management key instead of a normal inference key. A valid inference key can therefore still be rejected.

**Find a saved key → Scan** is optional. It reads only the selected `~/.env` file and/or app-inherited environment after you request it. Opening the form doesn't scan or import anything. Candidates show their source, masked value, and detected report mode or scope. **Add** saves only that candidate. Detected options override the manual new-connection controls; **Update** preserves an existing connection's report options.

Discovery covers OpenRouter, SearchAPI, DataForSEO, Firecrawl, OpenAI API, Anthropic API, xAI API, SerpAPI, Tavily, Jina AI, Parallel, Valyu, and You.com. Ordinary OpenAI/Anthropic/xAI inference keys and Parallel search keys cannot be added to billing connectors. OpenRouter ordinary keys select key reporting; management keys select the wallet. DataForSEO pairs login/password values only from the same source.

Scanning accepts bounded literal dotenv assignments, not substitutions, shell blocks, or multiline values. It rejects symlinks and nonregular files. A missing file doesn't hide valid inherited candidates. Finder-launched apps may not inherit terminal exports; Headroom never runs your shell startup files. A variable name alone doesn't prove validity, ownership, or billing access.

## Readings and controls

Headings use email when returned, otherwise provider account IDs or a placeholder. OpenRouter reports **API key** or **Wallet** because its key API returns no account name or email. Custom names aren't requested or displayed. **Show in menu bar** pins a reading; unpinned accounts remain in the menu and settings. If all accounts are unpinned, a clickable gauge remains.

A single account spans the full menu row and settings pane. Multiple accounts use at most two columns, stacking in a narrow detail pane. Quota percentages round down to whole numbers; positive values below one percent show `<1%`. Credit amounts and balances retain their precision. Reset dates use your local timezone.

The account's three-dot menu contains **Reconnect…**, **Dashboard**, and **Remove account**. A connection binds the provider identity when one is returned. A different identity, or a later missing identity, is rejected. To change the account, remove that connection and add another. Connectors without stable identity cannot establish that a replacement key belongs to the same person.

## Refresh and renewal

Checks run at launch and after connecting. Claude checks five minutes after a successful read; opening the menu doesn't shorten that interval. Other providers check after one minute, or when opening the menu with readings at least 30 seconds old. The menu captures fetched data when opened; reopen it to see new fetch results. The menu bar and settings update independently. No usage history is kept.

Claude attempts renewal within 15 minutes of token expiry on its next usage check, or once after HTTP 401. It can't renew while your Mac sleeps or is offline. A missing refresh token, revocation, or uncertain exchange can require sign-in. Grok renewal belongs to its selected helper. Expired Codex or manually entered tokens still need reconnection.

Claude HTTP 429 responses start an account-specific cooldown of 10–30 minutes. The settings window shows **Retry after** and disables Refresh until then. Earlier network failures can lengthen the first cooldown. Other failures back off for 2, 4, 8, 16, then at most 30 minutes. These are app defaults, not published provider limits or `Retry-After` handling. Cooldowns are in memory; relaunch or reconnect clears them.

Authentication, scope, identity, and Keychain-access failures pause that account until explicit retry or reconnection. Reads and resets don't overlap for the same account; automatic checks pause during sign-in. Manual refresh works outside a Claude rate-limit cooldown.

## Keychain access and recovery

Ordinary direct Keychain reads suppress interaction. If blocked, use **Allow Keychain access** for the affected connection and choose **Always Allow** for that entry. Don't reset the login Keychain or approve unrelated entries. Explicit saves and removals can also request access. Signing or moving a build can require new approvals.

For Claude, existing connections opt into ongoing access through macOS's `/usr/bin/security` tool. A successful new Headroom sign-in enables that path for its profile. This avoids depending on a Headroom ACL grant that helper writes can replace. A locked or differently protected item can still block access; brokered reads can briefly show system UI before timing out. An uncertain renewal pauses checks and requires **Reconnect…**. [Security](../SECURITY.md) summarizes credential boundaries.

Compare readings with the provider dashboard, then quit and reopen to check persistence. Use **Reconnect…** for expired credentials. Removing a connection affects only its Headroom profile; it doesn't revoke tokens remotely or remove other CLI logins.
