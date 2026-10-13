# Usage Monitor PoC

Local macOS 14+ menu-bar app, written in Swift 6 with AppKit and SwiftUI. This first PoC tests independent **Claude subscription** accounts. Codex and other providers are not implemented yet.

## Run

Requires Xcode command-line tools and Claude Code installed at `~/.local/bin/claude`, `/opt/homebrew/bin/claude`, or `/usr/local/bin/claude`. The scoped Keychain naming was checked against Claude Code **2.1.291**.

```sh
swift test
bash scripts/build-app.sh
open .build/UsageMonitor.app --args --window
```

The app runs in the menu bar after its account window closes. To inspect two fixture accounts without authentication or live requests:

```sh
open -n .build/UsageMonitor.app --args --demo
```

The build is Apple Silicon, locally ad-hoc signed, and **not notarized**. Nothing installs into `/Applications` or replaces an existing app.

## Connect accounts

1. Click **Add Claude account**. Sign-in starts without asking for a label.
2. Open the generated link in the browser profile for that Claude account. Or copy the link to a different device. The official helper owns PKCE, state, and token exchange.
3. Complete Claude's sign-in. Paste the displayed authorization code into the app if prompted. Do not paste codes, tokens, or passwords into an agent chat.
4. If macOS blocks the scoped Keychain read, click **Allow Keychain access**. Allow only this app-owned profile's entry; **Always Allow** permits subsequent checks.
5. Add another account and repeat in a different browser profile. Names default to the verified Claude display name, or email when no display name is returned. Use **Rename account…** in the account menu to customize it; leave the name blank to restore the automatic name. Existing custom labels are preserved.
6. Refresh each account, quit/reopen, then refresh both again. Compare five-hour and weekly figures to the corresponding Claude account pages.

## Boundaries

- Every account gets a new UUID and isolated Claude config and secure-storage directory under `~/Library/Application Support/UsageMonitorPoC/accounts/`. The helper receives an allowlisted environment, not inherited API keys or local tool credentials. `HOME` stays at the real macOS home so the system can find the login Keychain; explicit config overrides isolate Claude accounts.
- Reads target only the scoped `Claude Code-credentials-<path hash>` Keychain item or its private `.credentials.json` fallback. The default Claude login and browser cookies are never used. Helper tokens remain helper-owned.
- Metadata stores the verified account and organization IDs. A different identity, duplicate connection, missing/expired token, or unsupported response cannot silently become a valid account reading.
- Usage comes from private `/api/oauth/profile` and `/api/oauth/usage` reads. No inference requests are made by this app. This is **not an approved third-party OAuth integration**; provider policy and endpoint stability remain risks.
- Sign-in requests the helper's normal Claude Code permissions. It is not a read-only OAuth grant, even though this app only reads usage.
- Manual refresh only. Expired credentials require sign-in again. Automatic refresh-token rotation is deliberately deferred.
- Extra usage is spend against a monthly cap, **not prepaid wallet credits**. Unavailable fields do not become zeroes. Model-specific weekly windows are not shown in this PoC.
- Removal deletes only the selected app profile and scoped credentials. It does not revoke tokens remotely.

The interface uses native regular glass on macOS 26+, with a standard translucent material on older macOS. Zero remaining is red; above zero through 10% is orange. Reset dates use the local timezone and omit the year. The provider badge uses the Claude mark from the official claude.com favicon.

The user confirmed one successful live Claude sign-in and supplied a populated usage screenshot. Two-account live sign-in, quota comparison, and the corrected Keychain login path still need human verification.
