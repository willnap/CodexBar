# Native popup warning lights

Each account's dial carries a set of warning lights around the marks in its middle, in the manner of a car's
dashboard (2026-10-14):

- every light has its own spot, six down each side of the marks, and nothing shows there while it is off;
- amber is a caution, red means the account cannot be read or used, and a lit light glows faintly;
- the first popup opened after launch runs a bulb check: every light comes on for about a second, then the dials show
  their own;
- hovering a light gives one plain line (what is wrong, and when it helps, what to do); a light with a fix is a button.

The symbols show their problems plainly. Only the quota borrows the dashboard's fuel light, which already means
"running out".

| Spot | Light | Symbol | Lit when | Red when | Click |
| --- | --- | --- | --- | --- | --- |
| L1 | Sign in | `person.crop.circle.badge.exclamationmark.fill` | the login is expired, missing, rejected (401/403), or belongs to someone else | always | sign in (one account) or Settings |
| L2 | Provider incident | `exclamationmark.icloud.fill` | the status page reports an incident, or the usage service fails (5xx) | major/critical outage | status page |
| L3 | Maintenance | `wrench.and.screwdriver.fill` | the status page reports maintenance | — | status page |
| L4 | Rate limited | `hand.raised.fill` | the usage API answers 429 / rate-limited | — | — |
| L5 | Offline | `wifi.exclamationmark` | the provider can't be reached (offline, DNS, timeout, TLS) | — | refresh |
| L6 | Switching | `exclamationmark.arrow.triangle.2.circlepath` | a switch failed or Auto Switch is waiting (on its target), or this setup can't switch (on the active dial) | — | — |
| R1 | Quota | `fuelpump.fill` | a limit runs out before it resets at the current pace | a limit is reached | — |
| R2 | Spend cap | `creditcard.trianglebadge.exclamationmark.fill` | extra-usage spend is at 90 % of its cap | at the cap | — |
| R3 | Reading failed | `exclamationmark.triangle.fill` | a reading failed on our side (unreadable response, probe timeout), or an error nothing else explains | — | refresh |
| R4 | Helper | `terminal.fill` | claude-swap isn't responding, or a provider CLI is missing / won't start | missing CLI | Settings |
| R5 | Local logs | `folder.fill.badge.questionmark` | reading this Mac's usage logs stopped short, so token and spend totals are lower bounds | — | — |
| R6 | Old reading | `clock.badge.exclamationmark.fill` | the reading is older than three refresh intervals (at least 15 min; never with manual refresh), or claude-swap served last-known usage | — | refresh |

## Where the signals come from

- **Fetch failures.** Every fetch outcome already passes through `UsageStore.handleCredentialOutcome` with its real
  `Error`. `NativeOrbitFetchFault.light(for:provider:)` classifies it by type (never by wording):
  `ProviderCredentialFailure`, `ProviderFetchClassifiedError.Kind`, Claude/Codex OAuth and Kimi error cases, the HTTP
  status a Codex app-server request reports (`CodexRPCFailure`), `URLError` network codes, `DecodingError`, missing
  CLIs. Cancellation lights nothing. The light is stored in `nativeFetchFaults` and the next fresh, non-cached reading
  turns it off.
- **Keys.** Codex columns use their own visible account (`nativeCodexFaultScope`): copies of one login share an owner,
  and a hidden imported copy's failure must not light the column shown. Token accounts and single-account providers use
  the credential scope their outcomes are recorded under.
- **claude-swap.** Rows carry a structured `ProviderAccountCondition` from cswap's `usageStatus`
  (credential problems, usage unavailable, API-key accounts, unknown statuses); the adapter's own error lights the
  helper light on every claude-swap dial, and a failed switch lights the switching light on its target.
- **Status pages.** `UsageStore.status(for:)` (the existing poller).
- **Quota.** The dial's own windows (reached) and `NativeOrbitAccountProjection` lanes (`exhaustion` before `reset`).
- **Local logs.** `historyScanIsPartial` on the local reports only; provider statistics also call themselves partial
  while their day accumulates, which is not a failed read.
- **Fallback.** A column error that no other light explains lights *Reading failed* with that error, so no failure is
  left unlit.

The lights describe now: they step aside while the pointer reads another moment on the chart.

## Verifying

- `--native-preview --preview-orbit --preview-window --preview-open` with `CODEXBAR_PREVIEW_LIGHTS=all` lights every
  light in every dial (comma-separated kind names light just those).
- The debug proof dump (`--native-popup-preview-provider`) lists each column's store lights with their reasons under
  `warningLights`.
- `NativeOrbitWarningLightTests` covers classification, spots (distinct, inside the innermost ring, clear of the marks),
  recording and clearing, provider status, old readings, the spend cap and claude-swap conditions.
