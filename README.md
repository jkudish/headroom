# Usage Monitor PoC

Local macOS 14+ menu-bar app, written in Swift 6 with AppKit and SwiftUI. Connect multiple independent subscription and API accounts, including accounts that are not signed into your local CLIs. The menu dropdown is 360 points wide and scrolls; the account window can be resized.

## Run

Requires Xcode command-line tools. Subscription sign-in also requires the relevant official CLI: Claude Code or Codex, installed at `~/.local/bin/`, `/opt/homebrew/bin/`, or `/usr/local/bin/`. Key/token connections do not need a CLI. Helper contracts were checked with Claude Code 2.1.291 and Codex 0.153.4.

```sh
swift test
bash scripts/build-app.sh
open .build/UsageMonitor.app --args --window
```

The app runs in the menu bar after its account window closes. To inspect multiple providers with fixture data and no authentication or live requests:

```sh
open -n .build/UsageMonitor.app --args --demo
```

The build is Apple Silicon, locally ad-hoc signed, and **not notarized**. The build script does not install or replace an app.

## Connect accounts

1. Choose a provider from **Add account**.
2. For Claude or Codex, open the generated link in the browser profile for the account you want. The official helper owns token exchange. Claude may ask you to paste an authorization code into the app. Codex shows a device code: enter it on OpenAI's page, then wait for browser approval. Enable device code authorization in ChatGPT Security settings if required.
3. For other connectors, enter a separate key or token in the native connection form. Check the required credential type below. Do not paste codes, tokens, cookies, or passwords into an agent chat.
4. If macOS blocks a scoped Keychain read, click **Allow Keychain access**. Allow only that connection's entry; **Always Allow** permits later checks. Do not reset the login Keychain.
5. Repeat for another account. Names use provider identity when available; otherwise enter an optional name or use **Rename account…**. Claude defaults to the returned display name or email. Existing custom labels are preserved.
6. Compare each reading with its provider dashboard. Quit/reopen and refresh again to check persistence. Use **Reconnect account…** for expired credentials. To change the selected identity, remove that connection and add a new one.

## Connector reference

These are implemented reads, not a claim of live verification for every provider. Subscription quotas, wallet balances, API spend, and spending caps stay separate. Missing information is unavailable, never a fabricated zero or percentage.

| Connection | Credential | Reported information and limits |
|---|---|---|
| Claude | Independent official-helper sign-in | 5-hour/weekly remaining and reset; extra-usage monthly spend/cap, not prepaid credits |
| Codex | Independent official-helper device sign-in | Returned quota windows, reset, and credit quantities. Credits are not assumed to be USD. Identity binds a human and selected workspace |
| z.ai Coding Plan | Coding Plan API key; Global or China region | Returned quota types, periods, and resets; no wallet balance |
| OpenRouter wallet | Management key | Purchased-minus-used wallet USD credits |
| OpenRouter key | Ordinary API key; select key report | Key spend/caps, not wallet balance |
| OpenAI API | Organization Admin key; optional organization ID | Fully paginated UTC month-to-date API spend; no wallet balance |
| Anthropic API | Organization `sk-ant-admin` key | Fully paginated UTC month-to-date API spend; unavailable for individual accounts; no wallet balance |
| xAI API | Team-scoped Management API key with billing read access | Validated team's prepaid API balance; no SuperGrok quota, promotional credits, or API spend |
| Amp | Account access token | Private balance read: agent USD allowance, orb `a1.small` hours, individual/workspace credits when reported |
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

**Brave, Perplexity, Gemini, and Kagi are dashboard-only.** An independent billing credential/API contract is not implemented. Their forms collect no credentials. Librarium model variants share their billing family; they are not separate balances.

“Grokbot” is provisionally interpreted as Cursor Grok Bot. Another product needs its own connector.

## Boundaries

- Each connection has a UUID and private config directory under `~/Library/Application Support/UsageMonitorPoC/accounts/`. Claude and Codex helpers receive a complete allowlisted environment, not inherited keys, tokens, or proxies. `HOME` stays real for macOS Keychain discovery; explicit `CLAUDE_CONFIG_DIR`, secure-storage overrides, and `CODEX_HOME` isolate accounts.
- Claude reads only the scoped `Claude Code-credentials-<path hash>` Keychain item or its private `.credentials.json` fallback. Codex reads only the selected private `auth.json`. The app never imports default CLI logins or browser cookies. Manually supplied cookies are used only for their selected connector.
- Entered API keys/tokens stay in root/UUID-scoped Keychain entries, not metadata JSON. Removal affects only the selected app-owned profile and entries, not daily-driver credentials.
- When a provider returns identity, the connection binds it and rejects a different identity or a later missing identity. Codex claims are decoded metadata, not locally signature-verified; the provider validates the bearer. API reads without stable identity cannot prove that a pasted key still belongs to the same person.
- Provider requests use ephemeral sessions, fixed HTTPS hosts, no redirects, timeouts, and safe errors. No inference, paid search, purchase, or billing mutation is performed.
- Claude, Codex, Amp, Grok, Cursor, and z.ai usage interfaces are private or reference-backed. Jina balance text is experimental. They can change. This is **not an approved third-party Claude OAuth integration**; provider policy remains a risk.
- Sign-in requests the helper's normal Claude Code permissions. It is not a read-only OAuth grant, even though this app only reads usage.
- Manual refresh only. Expired credentials need reconnection. No automatic refresh-token rotation, polling, or usage history. Model-specific Claude weekly windows are not shown.
- Removal deletes only the selected app profile and scoped credentials. It does not revoke tokens remotely.

The interface lets native AppKit popovers, sheets, windows, and standard controls own their appearance. It does not add glass or visual-effect backgrounds inside those surfaces, following Apple's [Liquid Glass adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass). Unboxed accounts use thin dividers; the header **+** connects another service. Zero remaining is red; above zero through 10% is orange. Reset dates use the local timezone and omit the year. The Claude badge comes from the official claude.com favicon. Codex uses OpenAI's [Blossom mark](https://commons.wikimedia.org/wiki/File:OpenAI_logo_2025_(symbol).svg), rendered in monochrome for each appearance. These marks identify their providers and do not imply endorsement.

The automated suite covers selected-account credentials, identity changes, persistence, units, incomplete cost pagination, missing fields, over-plan credits, and safe errors. Fresh helper start/cancel checks do not complete real sign-in. New-provider authentication, live two-account readings, and comparisons against dashboards still need interactive verification.
