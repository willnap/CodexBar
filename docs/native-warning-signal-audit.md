# Native warning signal audit

The native catalogue has 51 independent cases. Every case below has a reachable production producer. The enum and renderer are not evidence of a producer: this table names the actual inputs and clearing conditions. Tests use typed responses, account snapshots, system callbacks and contained histories; they do not fetch accounts, query Keychain or launch the app. Focused execution is performed by the root task after integration.

The live path is `UsageStore.nativeOrbitAccounts` → `nativeOrbitAccount` / `nativeOrbitAmbientAccount` → `nativeOrbitWarnings` → `NativeOrbitWarningSignals.account`. Fetch faults enter through `handleCredentialOutcome` and remain keyed by provider plus verified account scope. Provider status enters through `refreshProviderStatus`; system callbacks enter through `NativeOrbitSystemSignals.start`, called by the real app lifecycle. Popup assembly adds provider-scoped peer warnings and the observed updater state.

| Key | Production producer | Clears when | Regression seam |
| --- | --- | --- | --- |
| outage | Status component/incident mapped by `NativeOrbitStatusWarningSignals.lights`, restricted to relevant product components | Relevant status becomes operational / incident resolves | Status warning tests |
| degraded | Relevant degraded-performance component or open degraded incident | Healthy targeted status | Status warning tests |
| modelTrouble | Open relevant incident/component names a model present in this account's measured usage report. Unreachable for Codex (account usage carries no model names) and for Claude and Kimi (machine-level usage) | Incident resolves or model is no longer in supplied recent history | Status warning tests |
| overloaded | `NativeOrbitFetchFault` receives HTTP 529, or HTTP 503 with explicit overload payload | Verified fresh successful account fetch | Typed-fault store recovery test |
| usageFailing | Typed usage HTTP 5xx, API failure, Claude Admin API HTTP error | Verified fresh successful account fetch | Typed-fault store recovery test |
| rateLimited | Typed OAuth/HTTP 429, including preserved Claude retry date and Kimi HTTP status | Verified fresh successful account fetch | Typed-fault store recovery test |
| maintenance | Relevant status maintenance component or decoded incident; scheduled within 24 h green, active amber | Completed/cancelled/resolved or outside time window | Status warning tests |
| statusUnknown | Failed real status fetch retained in `nativeStatusFetchFailures`, or unknown feed status | Accepted successful known status refresh, or status checks disabled | Status publication + warning tests |
| apiChanged | Typed invalid/undecodable provider response, decoding error, protocol error, usage HTTP 400/404/410 | Verified fresh successful account fetch | Typed-fault store recovery test |
| botCheck | Claude web typed `cloudflareChallenge` | Verified fresh successful account fetch | Typed-fault store recovery test |
| macOffline | Real `NWPathMonitor` callback reports no usable path | Callback reports satisfied path | System signal tests |
| unreachable | Typed provider network fault / URL transport DNS, connection or timeout error | Verified fresh successful account fetch | Typed-fault store recovery test |
| insecure | URL TLS / certificate error preserved through OAuth wrapping | Verified fresh successful account fetch | Typed-fault store recovery test |
| signIn | Typed missing/rejected credential or adapter login status | Verified fresh successful fetch / repaired adapter projection | Typed-fault recovery + adapter tests |
| keychain | Typed Claude Keychain revoked/error or adapter `keychainUnavailable`, retained as `credentialIssue` | Verified successful fetch / healthy adapter status | Typed-fault recovery + adapter projection tests |
| wrongAccount | Adapter `foreignCredential` projected to `.wrongAccount`, not display-text parsing | Adapter reports healthy matching credential | Adapter projection tests |
| permission | Typed permission-denied classification, usage HTTP 403, or missing organization | Verified fresh successful fetch | Typed-fault store recovery test |
| browserSession | Typed Claude web missing/invalid session cookie | Verified fresh successful fetch | Typed-fault store recovery test |
| plan | Provider subscription end date, already owner-paired, within 7 days; expired red | End date withdrawn or moves beyond 7 days | Account warning evaluator tests |
| billing | Preserved Claude subscription status past_due/unpaid/suspended, or Kimi inactive/status | Accepted active healthy metadata | Metadata + account evaluator tests |
| spend | Actual provider spend ≥90%/cap, or continuous measured spending (`sustainedSpendRate`) reaches the cap before reset and within 3 days | Extra usage disabled, or measured spend/allowance returns below threshold and projected risk clears | Live store disabled-extra-usage regression + account evaluator |
| credits | Measured prepaid balance below zero, or zero after a funded continuous run; continuous same-pool decline (`sustainedBalanceRate`) predicts ≤3 days | Measured positive balance/risk clears; unlocked/unexpired cloud metadata | Account evaluator + metadata tests |
| limit | Measured quota ≥100% (red), or remaining at or below the lowest quota-warning threshold (`FuelReserve`, amber) | Measured allowance returns above the threshold | Account evaluator tests |
| notReported | Used quota window has no reset | Provider reports complete applicable quota/reset | Account evaluator tests |
| limitsChanged | Current quota cadence differs from the same account's recorded native quota cadence, within 24 h of the change; popup windows are matched to their history lanes (`historyID`) | 24 h passes / no differing prior cadence evidence | Account evaluator tests |
| behindPace | Measured `UsagePace` behind/farBehind once 3 % of the window has passed, or ≥40% remains within last day of weekly/monthly quota | Measured pace returns to even range / window resets | Account evaluator tests |
| aheadOfPace | Measured `UsagePace` slightlyAhead/ahead once 3 % of the window has passed | Measured pace returns to even range | Account evaluator tests |
| farAheadPace | Measured `UsagePace` farAhead once 3 % of the window has passed | Measured pace returns to even range | Account evaluator tests |
| spike | Complete completed account days: current-day measured lower bound ≥3× preceding seven daily values (including real Codex accumulating receipts) | Daily usage returns below threshold / evidence no longer sufficient | Account evaluator tests |
| idle | Named non-free plan (snapshot or `reportedPlan`) plus complete previous seven civil days of measured zero account-level use, no positive current-day lower bound and no quota increase | Usage resumes / paid plan ends / coverage ceases to prove inactivity | Account evaluator tests |
| resetLate | Fresh provider reading remains ≥100% more than ten minutes after its advertised reset | Fresh quota resets or schedule changes | Account evaluator tests |
| earlyReset | Existing `NativeOrbitResetEvent.events` classifies account history as provider/unexplained early reset, ≤24 h old | Event ages beyond 24 h | Account evaluator tests |
| newSavedReset | A reset inventory reading within the last 24 h counted more available resets than the one before it | Next inventory no longer rose / observation ages beyond 24 h | Account evaluator tests |
| switching | Existing switch failure/waiting source plus active account pressure and measured same-provider peer with <50% used of matching limit | Switch succeeds/wait ends / pressure or peer room clears | Peer warning tests + existing switching tests |
| allExhausted | Every account in same-provider peer cohort has a measured exhausted limit | Any account gains room or unknown evidence prevents all-account claim | Peer warning tests |
| usedElsewhere | Measured quota-rise intervals totalling ≥2 points in one lane within a day (`minimumUnexplainedRise`), each covered by a complete fresh account-attributed local request stream with no requests/unattributed activity in it; whole-day zero fallback requires complete current-day local absence | Local usage evidence arrives / quota consumption falls outside interval | Account evaluator tests |
| oldReading | Existing refresh-age threshold or adapter last-known fallback | Fresh reading within age threshold; age-only path disabled in Manual | Existing store warning tests |
| partialReading | Explicit synthetic/missing provider window or unknown named quota usage | Complete measured provider window returns | Account evaluator tests |
| unpriced | Actual report has unpriced requests in the dial's selected range | Priced report replaces it / unpriced usage ages out | Account evaluator tests |
| unattributed | Actual local report records unattributed days within the dial's selected range | Attribution improves / affected days age out | Account evaluator tests |
| timeZone | Real `NSSystemTimeZoneDidChange` callback records old/new zone and time | 24 h passes | System signal tests |
| unknownError | Unclassified typed fetch failure or unexplained source error | Verified fresh successful fetch / source error clears | Typed-fault recovery + unexplained-error tests |
| helper | Typed missing helper, process-start failure, or probe timeout; adapter list failure | Verified fresh successful fetch / successful adapter list | Typed-fault recovery + adapter tests |
| update | Real observed updater availableVersion; typed unsupported adapter schema; decoded Claude reset reason cli_version | Updater no longer reports newer version / supported adapter / eligible CLI response | Metadata + typed-fault recovery; updater bridge |
| localLogs | Actual local cost scan reports historyScanIsPartial | Complete local rescan replaces report | Existing partial-total/store warning seam |
| folderAccess | Configured Antigravity additional profile folder intersects actual bookmark restore failures | Folder is restored or removed from configured source paths | Pure folder evaluator called by live store |
| storage | Real `PlanUtilizationHistoryStore.save` failed-provider set published by persistence coordinator | Successful write for that provider | System signal/persistence tests |
| notifications | Read-only macOS notification settings reports denied while quota/predictive/session warnings enabled | Authorization becomes enabled or warnings are turned off | System signal tests |
| autoRefreshOff | Live SettingsStore refreshFrequency is Manual | Refresh frequency becomes automatic | Store warning test |
| refreshStuck | Provider refresh begin/end instrumentation records start; 120 s task publishes observable slow state | Tracked refresh completes or provider state is cleared | Store refresh-activity test |
| unavailableHere | Ambient provider configuration/availability produces unavailableMessage; typed unsupported-platform fetch also classifies explicitly | Configuration/source becomes supported and refresh succeeds | Typed-fault recovery; ambient live presentation |

## Catalogue variants still limited

A reachable primary condition does **not** mean every trigger variant in the design catalogue has been implemented. These remain explicit limitations:

- Plan downgrade comparison is not recorded; plan currently uses provider-reported ending/expiry.
- Changed quota cadence is detected; removed/added limits and absolute cap changes are not comprehensively compared.
- Spike uses complete completed account daily token history and allows a current-day lower bound to prove excess; hourly/spend anomaly baselines are not yet evaluated. Idle uses the previous seven completed civil days, requires a recognized paid plan and sufficient account-attributed report coverage, and refuses positive current usage or quota contradictions. Codex server account receipts provide a real producer. Claude machine/organization-only logs deliberately remain excluded; recognizing a Claude plan label does not turn those logs into account evidence.
- Status incident feed support depends on the provider's feed. Model incidents require real model evidence; unsupported feeds stay conservative. Authentication-component incident context is not appended to rejected-login hover text.
- Browser/session, bot-check and Keychain primary typed sources are covered for Claude. Every provider's existing textual error wrapper has not been upgraded. OpenAI dashboard Cloudflare/mismatched-email adjunct failures are not yet uniformly typed into these lights.
- `folderAccess` applies only to currently configured bookmark-backed Antigravity additional profile folders. A provider with no configured granted log folder does not inherit another provider's folder failure.
- `storage` tracks persisted plan/native history writes. Other independent log persistence failures are not comprehensively instrumented.
- `refreshStuck` tracks the provider refresh coordinator; independent helper/account-only work outside that coordinator does not inherit a false provider deadline.
- The updater bridge and system observations are live app paths. Focused model tests establish their state behavior; no app was launched to exercise real outage, denial, billing, or full-disk conditions.

`usedElsewhere` also inspects exact local request timestamps between consecutive quota samples. Local requests up to 10 minutes before a rise count for it (the provider's reporting lag); earlier local activity does not suppress an independently observed later quota increase with no matching local requests. When local and remote use overlap inside the same sampling interval, the present data cannot reliably separate them. Missing/incomplete local evidence is not a claim that the account is not used elsewhere; no live account inspection is performed by these tests.
