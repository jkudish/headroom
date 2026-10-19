# Provider reference

These are implemented connectors, not a claim of live verification for every provider. Credential and display contracts below describe the current source; providers can change them independently. `Sources/UsageMonitor/Providers.swift` owns the service catalog.

Quotas, wallet balances, spending, and caps keep their own units. Missing information is unavailable, never a fabricated zero or percentage. Headroom doesn't enforce provider limits.

## Subscriptions and coding plans

| Connection | Credential | Readings and limits |
| --- | --- | --- |
| Claude | Independent Claude Code helper sign-in | 5-hour/weekly remaining and resets, profile tier, optional saved resets and promotional cloud credits, Extra usage monthly spend/cap. No prepaid Extra usage wallet or model-specific weekly windows. |
| Codex | Independent Codex helper device sign-in | Returned plan, quota windows, wallet credits, individual credit allowance, and supplemental reset inventory. Credits aren't assumed to be USD or raw tokens. Reset use requires confirmation. |
| Grok / SuperGrok | Official Grok helper browser sign-in, or manual access token | Provider-returned billing credits and verified profile identity. No invented 5-hour or weekly windows. Manual tokens need renewal. Not the xAI API account. |
| Grok Bot | Private sign-in window or manual session Cookie header | Cursor-backed verified identity, allowance, and trial information. Trial expiry isn't a recurring quota reset. Embedded SSO is experimental. |
| Amp | Account access token | Official `amp usage` in a private home with only the selected `sgamp_` token; private balance HTTP fallback. Supplemental dashboard query attempts independent Agent/Orb percentages. Dollars, Orb hours, and wallet credits remain separate. See below. |
| z.ai Coding Plan | Coding Plan API key; Global or China region | Returned quota types, periods, and resets. No wallet balance or documented key-to-email lookup. |

Claude optional reset and cloud-credit reads use a private usage extension, falling back to ordinary usage after HTTP 400/403. Malformed optional fields don't hide ordinary quotas. Saved reset expiry and promotional credit availability update locally at known time boundaries; these display updates don't poll the provider. See [Reset credits](reset-credits.md).

### Amp Orb coverage

The supplemental read uses the private SvelteKit query `rjke8/getAccountSettingsPanelData`. A bounded reference-table decoder reads email, subscription metadata, and `percentRemaining` from the `general` and `orb` fields in `subscriptionUsageBuckets`. It never executes JavaScript. Valid dashboard meters replace only their matching CLI meters. Invalid or missing supplemental fields don't discard valid CLI readings.

Reset dates require a known, active, future subscription that renews under the dashboard's payer, cancellation, and free-renewal conditions. The derived reset is two hours before `periodEndAt`. Unknown states omit the reset. Remaining hours use the provider's known scale; unrecognized machine-size scales use generic Orb hours rather than assuming `a1.small` hours.

**The dashboard query is source-backed and fixture-tested, but bearer acceptance and its authenticated payload remain unverified in Headroom.** The public frontend uses same-origin browser sessions. Headroom doesn't import those cookies. Missing Orb readings distinguish rejected requests, unrecognized responses, and absent Orb fields; the `AmpOrb` log category records fixed failure labels only.

The balance fallback handles optional organization text, tier names, independent legacy percentages, Orb hours, Agent dollars, and wallet credits. Display text doesn't establish an account ID. Dashboard comparisons still require live validation.

## API billing

| Connection | Credential | Readings and limits |
| --- | --- | --- |
| OpenRouter wallet | Management key | Purchased-minus-used wallet credits in USD. |
| OpenRouter key | Ordinary API key; key report | Key spending and caps, not the wallet balance. |
| OpenAI API | Organization Admin key; optional organization ID | Fully paginated UTC month-to-date API spend. No wallet balance. |
| Anthropic API | Organization `sk-ant-admin` key | Fully paginated UTC month-to-date API spend. Individual accounts and standard inference keys don't provide this read. No wallet balance or Claude subscription limits. |
| xAI API | Team Management key with billing read access | Validated team's prepaid API balance. No SuperGrok quotas, promotional credits, or API spend. |
| SearchAPI | API key | Monthly searches, remaining search credits, allowance, and reset. |
| DataForSEO | API login and API password from API Access | USD balance and all-time deposits-minus-balance as credits used. This is not monthly spend. The account read is free. |
| Firecrawl | Team API key | Remaining credits, plan cap, and billing period. Purchased/coupon credits can exceed the cap. |
| SerpAPI | API key | Monthly usage, allowance, and remaining searches. The free account endpoint requires the key in its query; URLs aren't logged. |
| Tavily | API key | Plan credit usage/allowance and separate key usage/cap. |
| Jina AI | API key | Experimental token balance parsed from the root response; changed formats fail visibly. |
| Parallel | Account API OAuth access token, not a search key | Prepaid USD balance and separate pending charges. Invoice accounts are labelled postpaid. |
| Valyu | Key with `billing:read` | Organization credits and pay-as-you-go spend in USD. |
| You.com | API key with account balance access | Individual/organization credit balance. |

API usage reads don't run inference, purchase credits, or issue paid searches. Some credentials still grant more than billing-read permissions. Use the least privilege accepted by the provider. See [Account setup](accounts.md) for optional key discovery.

## Paused and legacy services

Exa is paused and isn't offered for new connections or discovery. Saved Exa accounts remain removable and can open their dashboard, but don't poll. Credentials aren't deleted automatically.

Brave, Perplexity, Gemini, and Kagi have no implemented billing read and aren't offered for new connections. Legacy identifiers remain decodable so updates preserve saved data. Librarium model variants share a billing family; they aren't separate balances.

Grok Bot retains the storage identifier `cursor` for compatibility. It isn't a general Cursor billing connector. Provider marks and reference implementations are credited in [Third-party notices](../THIRD_PARTY_NOTICES.md).
