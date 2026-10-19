# Reset credits and expiry alerts

Unused reset credits can expire before you use them. Their expiry is separate from a quota window's normal reset time.

## Claude

**Available resets** counts saved resets from active, unpaused grants, including resets that can't yet be used because a limit hasn't been reached. The next expiry is a grant expiry, not a recurring refill date. Claude reset display is read-only; Headroom has no Claude reset-redemption action.

**Cloud credits** are promotional cloud-session dollars. They are separate from Extra usage monthly spending/caps and the prepaid Extra usage wallet. Expired or locked credits aren't shown as spendable. No OAuth endpoint for the prepaid wallet is established, so Headroom doesn't guess its balance or fetch browser cookies.

Known grant/credit time bounds update availability locally as time passes, without changing the last successful fetch time. Malformed supplemental fields are omitted without hiding ordinary usage.

## Codex

**Available resets** and the details sheet describe only records returned by the provider. A failed supplemental endpoint doesn't hide valid quotas.

To use a reset:

1. Choose **Use reset…** under the Codex account, or **Available resets…** in its account actions.
2. Select a listed credit and choose **Use reset…**.
3. Check the account and credit in the confirmation dialog. **Cancel** is the default.

**Confirmation consumes a finite provider credit.** Headroom rechecks the selected human/workspace identity and live inventory before sending the request. It saves a per-account/credit request UUID first and retains it after an uncertain response or restart. It never automatically retries or switches accounts or credits.

An uncertain result clears displayed usage and inventory and blocks another attempt until that account refreshes successfully. Failed refreshes and restarts don't restore stale eligibility. If the credit is gone or redeemed, replay is blocked. Headroom doesn't guarantee reconciliation of a lost successful response. Check refreshed limits and the provider dashboard before selecting another credit.

The consume endpoint is private and reference-backed. No real reset was consumed in development verification; tests inject synthetic responses.

## Expiry alerts

Enable **Reset expiry alerts** on each Claude or Codex account and allow macOS notifications. Headroom schedules reminders **12, 3, and 1 hour** before unused credits expire. If enabled late, only the latest missed threshold is sent, followed by future thresholds. Sent thresholds aren't replayed after refresh or relaunch.

Removing an account, disabling alerts, or refreshing away used credits cancels pending reminders. Missing or stale inventory doesn't schedule new reminders or cancel existing ones.

For persistent desktop alerts, choose **Alerts** for Headroom in **System Settings → Notifications**. macOS controls presentation, Focus, and delivery; Headroom can't force persistence. Clicking a notification opens that account's service. Alerts never consume a reset.

An orange dot on a pinned account's menu-bar icon marks unused resets expiring within 12 hours. An exclamation mark covers unpinned accounts. These badges work with desktop alerts off and don't need notification permission. Real notification delivery still needs interactive verification.
