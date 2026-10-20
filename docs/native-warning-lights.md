# Native popup warning lights

Each account's dial carries a set of warning lights around the marks in its middle, in the manner of a car's
dashboard (2026-10-14):

- every light has its own fixed spot, in rings filled outward from the marks in its middle (`NativeOrbitWarningBulbPositions`), and nothing shows there while it is off;
- amber is a caution, red means the account cannot be read or used, and a lit light glows faintly;
- the first popup opened after launch runs a bulb check, like a car at ignition: every light comes on while the gauges
  sweep to full, each group goes dark once its evidence has arrived, and after a dark beat the genuine warnings come back
  on as the dial settles. A group still waiting on its evidence stays lit;
- hovering a light gives one plain line (what is wrong, and when it helps, what to do); a light with a fix is a button.

The symbols show their problems plainly. Only the quota borrows the dashboard's fuel light, which already means
"running out".

The catalogue (generated from `NativeOrbitWarningLight.Kind`; the hover text is the light's explanation unless
an evaluator supplies a specific one):

| Light | Symbol | Hover text |
| --- | --- | --- |
| Outage (`outage`) | `bolt.horizontal.fill` | Service outage. |
| Degraded (`degraded`) | `hourglass` | Service is slow or unreliable. |
| Model trouble (`modelTrouble`) | `cpu.fill` | A model you use has an incident. |
| Overloaded (`overloaded`) | `person.3.fill` | Servers are overloaded. |
| Usage figures failing (`usageFailing`) | `chart.bar.xaxis` | Usage service failed. |
| Rate limited (`rateLimited`) | `hand.raised.fill` | Usage checks are rate limited. |
| Maintenance (`maintenance`) | `wrench.and.screwdriver.fill` | Service maintenance. |
| Status unknown (`statusUnknown`) | `icloud.dashed` | Service status unavailable. |
| Provider changed its data (`apiChanged`) | `curlybraces` | Cannot read usage response. |
| Blocked by a bot check (`botCheck`) | `shield.fill` | Browser verification required. |
| This Mac is offline (`macOffline`) | `wifi.slash` | This Mac is offline. |
| Can’t reach the provider (`unreachable`) | `network.slash` | Cannot reach the provider. |
| Secure connection failed (`insecure`) | `lock.open.fill` | Secure connection failed. |
| Sign in again (`signIn`) | `key.fill` | Sign in again. |
| Keychain access blocked (`keychain`) | `key.2.on.ring.fill` | Cannot open saved credentials. |
| Signed in as someone else (`wrongAccount`) | `person.text.rectangle.fill` | Login belongs to another account. |
| This login can’t read usage (`permission`) | `nosign` | Login cannot read usage. |
| Browser session unavailable (`browserSession`) | `safari.fill` | Browser session expired or missing. |
| Plan ending or changed (`plan`) | `calendar` | Plan ending or expired. |
| Billing problem (`billing`) | `creditcard.fill` | Payment problem. |
| Extra-usage spend (`spend`) | `banknote.fill` | Extra usage may incur charges. |
| Credits low (`credits`) | `creditcard.rewards.fill` | Prepaid credits running low. |
| Limit (`limit`) | `fuelpump.fill` | Allowance running out. |
| Not reported (`notReported`) | `questionmark` | Limit or reset time missing. |
| Limits changed (`limitsChanged`) | `slider.horizontal.3` | Quota period changed. |
| Behind pace (`behindPace`) | `tortoise.fill` | Less of the limit used than of its time. |
| Ahead of pace (`aheadOfPace`) | `hare.fill` | More of the limit used than of its time. |
| Far ahead of pace (`farAheadPace`) | `flame.fill` | Far more of the limit used than of its time. |
| Unusual usage (`spike`) | `waveform.path.ecg` | Today’s usage is at least 3× the daily average. |
| Account idle (`idle`) | `zzz` | No usage for 7 days. |
| Reset overdue (`resetLate`) | `alarm.fill` | Allowance still exhausted after reset. |
| Limits reset early (`earlyReset`) | `clock.arrow.circlepath` | Allowance reset early. |
| New saved reset (`newSavedReset`) | `gift.fill` | Saved reset added. |
| Switching (`switching`) | `arrow.left.arrow.right` | Account switch needs attention. |
| No account has room (`allExhausted`) | `xmark.octagon.fill` | Every account has an exhausted allowance. |
| Used on another device (`usedElsewhere`) | `desktopcomputer.and.macbook` | Usage rose without matching local requests. |
| Old reading (`oldReading`) | `clock.fill` | Usage reading is stale. |
| Partial reading (`partialReading`) | `circle.lefthalf.filled` | Usage reading incomplete. |
| Some usage isn’t priced (`unpriced`) | `tag.slash.fill` | Missing prices make spend incomplete. |
| History not tied to this account (`unattributed`) | `person.slash.fill` | Some requests have no account identity. |
| Time zone changed (`timeZone`) | `globe.fill` | Time zone changed. |
| Something else went wrong (`unknownError`) | `exclamationmark.triangle.fill` | Usage refresh failed. |
| Helper not working (`helper`) | `terminal.fill` | Required helper unavailable. |
| Update needed (`update`) | `arrow.down.to.line` | Update available. |
| Local logs incomplete (`localLogs`) | `doc.text.fill` | Unreadable logs make totals incomplete. |
| Log folder access lost (`folderAccess`) | `folder.fill` | Cannot open usage-log folder. |
| Can’t save history (`storage`) | `externaldrive.fill` | Cannot save usage history. |
| Notifications off (`notifications`) | `bell.slash.fill` | CodexBar notifications blocked. |
| Auto refresh off (`autoRefreshOff`) | `autostartstop.slash` | Automatic refresh off. |
| Refresh taking too long (`refreshStuck`) | `arrow.clockwise` | Refresh taking over 2 minutes. |
| Not available here (`unavailableHere`) | `app.slash.fill` | Usage source unsupported here. |

## Quota, pace and money

- **Fuel** (`limit`, amber): as a car's low-fuel light, it reports how much is left, not how fast it goes: a window
  at or below the lowest of the provider's quota-warning thresholds (Settings, 20 % by default; windows of a day or
  less take the session thresholds, longer ones the weekly). Red when a limit is reached. How fast it is going is the
  hare's (`aheadOfPace`, 2–12 points ahead of even pace) or the flame's (`farAheadPace`, more than 12); the tortoise
  (`behindPace`) reports usage more than 6 points behind, or 40 % or more left within a weekly limit's last day. A
  lit fuel light replaces the pace lights.
- No pace light until 3 % of the window has passed, as the menu's pace: a single request a few minutes into a
  window would otherwise read as far ahead.
- Pace lights say the two numbers they compare, used and elapsed: "Weekly limit: 33% used, 4% of the week gone."
- Each light names its window: the provider's own windows by their length ("Weekly limit"), a window of its own by
  its title too ("Weekly limit (Fable only)"). When several windows raise the same light, it shows the largest gap
  from pace or the least left.
- Quota readings count as current for 45 minutes (`maximumQuotaAge`): the slowest automatic refresh (30 minutes) plus
  the fetch. The old-reading light waits three refresh intervals (at least 15 minutes); with adaptive refresh, three of
  its current interval and never under those 45 minutes.
- **Used elsewhere** (`usedElsewhere`): within the last day, one of the account's own quotas rose at least 2 points
  (`minimumUnexplainedRise`) with no local request in those intervals or the 10 minutes before each
  (`quotaReportingLag`; providers count a request minutes after it is made). Whole-number readings can step one point
  with nothing used here, as Codex's weekly limit did on 2026-10-20 with no Codex activity on this Mac for three hours. Server period
  totals are never readings, so they never count as a rise.
- **Money forecasts** (credits within 3 days, spending cap): the immediately prior receipt must continue the change
  (same pool or cycle, strictly moving, 10 minutes to 2 hours old); the rate then runs back through the unbroken run
  of the last day. A spending cap is only forecast when spending would reach it within 3 days.
- Kimi's subscription expiry is its monthly pool's renewal, so it never lights the plan light.

## Where the signals come from

- **Fetch failures.** Every fetch outcome already passes through `UsageStore.handleCredentialOutcome` with its real
  `Error`. `NativeOrbitFetchFault.light(for:provider:)` classifies it by type (the one exception: a 503 whose body names the provider's `overloaded` error lights *Overloaded*):
  `ProviderCredentialFailure`, `ProviderFetchClassifiedError.Kind`, Claude/Codex OAuth and Kimi error cases, the HTTP
  status a Codex app-server request reports (`CodexRPCFailure`), `URLError` network codes, `DecodingError`, missing
  CLIs. Cancellation lights nothing. The light is stored in `nativeFetchFaults` and the next fresh, non-cached reading
  turns it off.
- **Keys.** Codex columns use their own visible account (`nativeCodexFaultScope`): copies of one login share an owner,
  and a hidden imported copy's failure must not light the column shown. Token accounts and single-account providers use
  the credential scope their outcomes are recorded under.
- **claude-swap.** This Mac's own Claude read never lights a claude-swap row: it can fail (a rotated keychain item it may not read without a prompt) while claude-swap reads the same login.
  Rows carry a structured `ProviderAccountCondition` from cswap's `usageStatus`
  (credential problems, usage unavailable, API-key accounts, unknown statuses); the adapter's own error lights the
  helper light on every claude-swap dial, and a failed switch lights the switching light on its target.
- **Status pages.** `UsageStore.status(for:)` (the existing poller).
- **Quota.** The dial's own windows (reached) and `NativeOrbitAccountProjection` lanes (`exhaustion` before `reset`).
- **Local logs.** `historyScanIsPartial` on the local reports only; provider statistics also call themselves partial
  while their day accumulates, which is not a failed read.
- **Fallback.** A column error that no other light explains lights *Reading failed* with that error, so no failure is
  left unlit.

Hovering another moment on the chart re-evaluates the measured lights for that moment (`NativeOrbitWarningEvaluation`); a light at a future moment is read against the dashed projection and carries no caption.

## Verifying

- `--native-preview --preview-orbit --preview-window --preview-open` with `CODEXBAR_PREVIEW_LIGHTS=all` lights every
  light in every dial (comma-separated kind names light just those).
- The debug proof dump (`--native-popup-preview-provider`) lists each column's store lights with their reasons under
  `warningLights`.
- `NativeOrbitWarningLightTests` covers classification, spots (distinct, inside the innermost ring, clear of the marks),
  recording and clearing, provider status, old readings, the spend cap and claude-swap conditions.
