# Usage Monitor PoC

Local macOS 14+ menu-bar app, written in Swift 6 with AppKit and SwiftUI. Connect multiple independent subscription and API accounts, including accounts that are not signed into your local CLIs. A native macOS menu stacks all accounts in 360-point content rows; AppKit handles overflow. One clickable menu-bar area combines the visible accounts' logos and up to two quota readings (session then weekly), or their available balance. Missing readings show a dash, not zero. Hover tooltips are disabled; the accessibility label still identifies accounts and meters. The account window can be resized.

## Run

Requires Xcode command-line tools. Subscription sign-in also requires the relevant official CLI: Claude Code or Codex, installed at `~/.local/bin/`, `/opt/homebrew/bin/`, or `/usr/local/bin/`. Key/token connections do not need a CLI. Helper contracts were checked with Claude Code 2.1.291 and Codex 0.153.4.

```sh
swift test
bash scripts/build-app.sh
open .build/UsageMonitor.app --args --window
```

The app appears in the Dock and Command-Tab while its account window is open; closing it returns to menu-bar-only mode. To inspect multiple providers with fixture data and no authentication or live requests:

```sh
open -n .build/UsageMonitor.app --args --demo
```

The build is Apple Silicon, signed with Joachim Kudish's personal Apple Development certificate (team `K7RS6S7JX2`), and **not notarized**. The build script requires that certificate and fails rather than falling back to an ad-hoc identity. It does not install or replace an app.

## Connect accounts

1. Choose a provider from **+ Connect service…** in the menu, or the **+** in the account window.
2. For Claude or Codex, open the generated link in the browser profile for the account you want. The official helper owns token exchange. Claude may ask you to paste an authorization code into the app. Codex shows a device code: enter it on OpenAI's page, then wait for browser approval. Enable device code authorization in ChatGPT Security settings if required.
3. For other connectors, enter a separate key or token in the native connection form. Check the required credential type below. Do not paste codes, tokens, cookies, or passwords into an agent chat.
4. Ordinary refreshes disable both legacy-Keychain interaction and `LAContext` authentication UI. Blocked access stays in the app instead of requesting permission repeatedly. Click **Allow Keychain access** for that connection; **Always Allow** permits later checks. After moving from an ad-hoc build to the personal signing certificate, each existing entry may need one new approval. Explicit saves/removals may also request access. Do not reset the login Keychain or approve unrelated entries.
5. Repeat for another account. Headings use email when returned, otherwise a provider account ID or a new-account placeholder. Custom names are no longer requested or displayed; legacy labels remain in storage. **Show in menu bar** toggles each account's bar reading without hiding it from the dropdown. All-hidden still leaves a clickable gauge.
6. Compare each reading with its provider dashboard. Quit/reopen and refresh again to check persistence. Use **Reconnect account…** for expired credentials. To change the selected identity, remove that connection and add a new one.

## Connector reference

These are implemented reads, not a claim of live verification for every provider. Subscription quotas, wallet balances, API spend, and spending caps stay separate. Missing information is unavailable, never a fabricated zero or percentage.

| Connection | Credential | Reported information and limits |
|---|---|---|
| Claude | Independent official-helper sign-in | 5-hour/weekly remaining and reset; recognized current profile tier/family overrides cached helper plan on every refresh; extra-usage monthly spend/cap, not prepaid credits |
| Codex | Independent official-helper device sign-in; Copy code button | Returned plan (Pro 100/200/500), quota windows, reset, wallet credits and individual credit allowance. Supplemental reset inventory/details and confirmed selected-credit redemption. Credits are not assumed to be USD or raw tokens. Identity binds a human and selected workspace |
| z.ai Coding Plan | Coding Plan API key; Global or China region | Returned quota types, periods, and resets; no wallet balance or established API-key account-email lookup |
| OpenRouter wallet | Management key | Purchased-minus-used wallet USD credits |
| OpenRouter key | Ordinary API key; select key report | Key spend/caps, not wallet balance |
| OpenAI API | Organization Admin key; optional organization ID | Fully paginated UTC month-to-date API spend; no wallet balance |
| Anthropic API | Organization `sk-ant-admin` key | Fully paginated UTC month-to-date API spend; unavailable for individual accounts; no wallet balance |
| xAI API | Team-scoped Management API key with billing read access | Validated team's prepaid API balance; no SuperGrok quota, promotional credits, or API spend |
| Amp | Account access token | Private balance read plus experimental dashboard settings query: separate Agent/Orb percentages, tier, reset date and email when returned; individual/workspace credits remain separate. The agent cap is not displayed. If the dashboard query is unavailable, balance-text readings remain and missing Orb usage stays unavailable |
| Grok / SuperGrok | Manually supplied Grok OAuth access token | Private CLI billing: reported credit period and prepaid credits. No independent 5-hour/weekly windows established; no in-app OAuth or automatic token renewal yet |
| Cursor Grok Bot | Manually supplied Cursor session Cookie header | Private Grok Bot allowance or trial. Separate from SuperGrok; trial expiry is not a recurring quota reset |
| SearchAPI | API key | Monthly searches, remaining search credits, allowance, reset |
| DataForSEO | API login and API password from API Access | USD balance; all-time deposits-minus-balance as credits used, not monthly spend. The account read is free |
| Firecrawl | Team API key | Remaining credits, plan cap, billing period. Purchased/coupon credits may exceed the plan cap |
| SerpAPI | API key | Monthly usage, allowance, remaining searches. The free account API requires its key in the query; URLs are not logged |
| Tavily | API key | Plan credit usage/allowance and separate key usage/cap |
| You.com | API key with account balance access | Individual/organization credit balance |
| Parallel | Account API OAuth access token, not a search key | Prepaid USD balance and pending charges separately; invoice accounts are labelled postpaid |
| Valyu | Key with `billing:read` | Organization credits and pay-as-you-go spend in USD |
| Exa | Team Management service key plus selected API key ID | Selected-key 30-day spend; requires Team Management access; no wallet balance |
| Jina AI | API key | Experimental root-response token balance; changed format fails visibly |

Brave, Perplexity, Gemini, and Kagi have no implemented billing connector and are no longer offered in either connection menu. Legacy provider identifiers remain decodable so an update does not destroy saved data. Librarium model variants share their billing family; they are not separate balances.

“Grokbot” is provisionally interpreted as Cursor Grok Bot. Another product needs its own connector.

## Boundaries

- Each connection has a UUID and private config directory under `~/Library/Application Support/UsageMonitorPoC/accounts/`. Claude and Codex helpers receive a complete allowlisted environment, not inherited keys, tokens, or proxies. `HOME` stays real for macOS Keychain discovery; explicit `CLAUDE_CONFIG_DIR`, secure-storage overrides, and `CODEX_HOME` isolate accounts.
- Claude reads only the scoped `Claude Code-credentials-<path hash>` Keychain item or its private `.credentials.json` fallback. Codex reads only the selected private `auth.json`. The app never imports default CLI logins or browser cookies. Manually supplied cookies are used only for their selected connector.
- Entered API keys/tokens stay in root/UUID-scoped Keychain entries, not metadata JSON. Removal affects only the selected app-owned profile and entries, not daily-driver credentials.
- When a provider returns identity, the connection binds it and rejects a different identity or a later missing identity. Codex claims are decoded metadata, not locally signature-verified; the provider validates the bearer. API reads without stable identity cannot prove that a pasted key still belongs to the same person.
- Provider requests use ephemeral sessions, fixed HTTPS hosts, no redirects, timeouts, and safe errors. No inference, paid search or purchase is performed. The only finite-resource write is explicitly confirmed Codex reset redemption; refresh and sign-in never redeem credits.
- Claude, Codex, Amp, Grok, Cursor, and z.ai usage interfaces are private or reference-backed. Jina balance text is experimental. They can change. This is **not an approved third-party Claude OAuth integration**; provider policy remains a risk.
- Sign-in requests the helper's normal Claude Code permissions. It is not a read-only OAuth grant, even though this app only reads usage.
- Manual refresh only. Expired credentials need reconnection. No automatic refresh-token rotation, polling, or usage history. Model-specific Claude weekly windows are not shown.
- Removal deletes only the selected app profile and scoped credentials. It does not revoke tokens remotely.

The interface uses a native AppKit `NSMenu` with transparent hosted account rows, matching CodexBar's presentation mechanism rather than a fixed-height popover. Menus, sheets, windows, and standard controls own their appearance; no glass/effect background is injected. This follows Apple's [Liquid Glass adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass). Unboxed accounts use thin dividers, with no account switcher or local-log history. Error paragraphs use readable primary text beside a warning icon. Zero remaining is red; above zero through 10% is orange. Reset dates use the local timezone and omit the year. The Claude badge comes from the official claude.com favicon. Codex uses OpenAI's [Blossom mark](https://commons.wikimedia.org/wiki/File:OpenAI_logo_2025_(symbol).svg), rendered in monochrome for each appearance. Amp uses its [official app icon](https://ampcode.com/app-icon.svg), rasterized to 128 pixels. Other providers use a letter badge. These marks identify their providers and do not imply endorsement.

Codex **Available resets** comes from the provider; details describe only listed records. An unavailable supplemental endpoint does not hide valid quotas. Choose **View / use resets…** directly in the menu or account window, select **Use this reset…**, and confirm the account and credit in the modal (Cancel is the default). The app rechecks the bearer human/workspace and live inventory before POSTing to the reference-backed `wham/rate-limit-reset-credits/consume` endpoint. It persists a per-account/credit request UUID before sending, reuses it after an uncertain response or restart, and never automatically retries or falls back to another account/credit. An uncertain result needs a refresh before deciding what to do. No real reset was consumed in development or verification; redemption tests use injected fixture HTTP only. Provider contracts can change.

Amp's current public frontend uses the SvelteKit query `rjke8/getAccountSettingsPanelData` for `user.email`, subscription metadata, and `subscriptionUsageBuckets.general/orb.percentRemaining`. This private GET may change or reject access tokens; no browser cookies are imported. A bounded reference-table reader decodes only those fields, never executes JavaScript, and leaves unsupported fields unavailable. Reset dates require an active, future subscription that renews under the dashboard's cancellation/free-renewal and payer conditions; they occur two hours before `periodEndAt`. Unknown or nonrenewing states omit the reset without discarding quotas, email, tier, or wallet credits. Dashboard quotas replace the CLI dollar-derived allowance rather than combining different meters. Amp percentage text follows its frontend: exact 0/100, `<0.5`, `>99.5`, and whole-number rounding elsewhere. Other providers keep fractional formatting. This query is source-backed and fixture-tested, not yet live-authenticated in this app.

An uncertain reset invalidates the displayed usage and inventory. No reset can be attempted until this account refreshes successfully; failed refreshes and restarts do not restore stale eligibility. The original request UUID remains saved. If the credit disappeared or became redeemed, replay is blocked: this app does not guarantee reconciliation of a lost successful response. Inspect the refreshed limits before selecting another credit.

The automated suite covers selected-account credentials, identity changes, persistence, units, incomplete cost pagination, missing fields, over-plan credits, and safe errors. Fresh helper start/cancel checks do not complete real sign-in. New-provider authentication, live two-account readings, and comparisons against dashboards still need interactive verification.
