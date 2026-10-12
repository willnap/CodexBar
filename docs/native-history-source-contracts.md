# Native account history source contracts

Rules for every value a native dial complication may show. The complications
themselves, their per-provider sources and the verification loop are described
in `docs/native-complications.md`.

## Zero, unknown and not applicable

- **0** whenever data covers the period and shows no activity: a complete local
  scan with no events in the period, account buckets whose coverage is
  established (the endpoint omits only zero days), a provider-reported zero, or
  a received empty list (an eligible account's empty grants list is 0 banked
  resets). A quiet stretch before an inspected instant inside covered data is 0.
- **"—" (unknown)** when no data covers the period: no source, an incomplete
  scan for that period, before the data begins. Values are never synthesized.
- **Not applicable** (the provider has no such concept, or the account is
  ineligible, e.g. `cedar_ember` `eligible: false`) is distinct from both and
  renders the corner's icon with the slash modifier.

The icon-bearing corners follow this one vocabulary:

| Corner | Zero / applies | Unknown | Not applicable |
| --- | --- | --- | --- |
| Banked resets (bottom leading) | one outlined reset glyph, plus one outlined glyph per used reset; filled glyphs for banked ones | "—", like every other corner | slashed reset glyph: providers without banked resets |
| Additional usage (bottom trailing) | plain rewards-card icon at zero, tinted while usage accrues | faint icon: loading, or hovering an instant no spend/balance reading covers | slashed icon: turned off, or never reported by this account |

`arrow.uturn.backward.circle` and `creditcard.rewards.fill` have no SF Symbols
slash variant (`.symbolVariant(.slash)` silently draws the plain glyph), so
`NativeOrbitSlashableGlyph` draws the system slash layer of `circle.slash`
(palette rendering, circle layer clear) over the glyph with a clearance cut
along it, as the UsageIndicator component does; symbols that have a slash
variant use it directly. The dial's other glyphs are identity marks (provider
logo, account badge), not readings.

Coverage also decides whether a real total is labelled complete or a recorded
subtotal.

## Spend corner

The top-leading corner shows spend for the selected Day / 7D / 30D period:
the period cost from the account's usage report (list-price estimate from
local sessions, labelled Estimated), else a provider period reading whose
window matches. A billing-cycle amount such as Claude's monthly extra usage is
never relabelled as a calendar-period total; it appears only in the
bottom-trailing corner, which reads "Off" when the provider reports the extra
usage window as disabled (`ProviderCostSnapshot.isDisabled`).

## Claude monthly spend and reset inventory (claude-swap)

Claude's OAuth usage response has a typed `spend.used` money object
(`amount_minor`, `exponent`, `currency`), independent of whether extra usage is
enabled. An explicit reported zero is a real measurement; missing money is
unknown; a configured cap on disabled extra usage is not an active budget.

claude-swap 0.26 drops disabled extra usage, ignores typed money and has no
reset inventory. Two reversible patches fix its installed copy:

- `Scripts/patch_claude_swap_spend.py` forwards typed monthly spend with
  additive `enabled` and `period: "Monthly"` fields;
- `Scripts/patch_claude_swap_complications.py` requests the `cedar_ember`
  inventory on the existing usage read and emits `resetCredits` only for an
  eligible account with a received `grants` list. Ineligible accounts and
  missing lists emit nothing, so the dial shows "—", not 0. The inventory
  read presents Claude Code's identity (`claude-cli/<installed version>
  (external, cli)`, read from the install layout); Claude answers cswap's own
  `claude-swap/1.0` with `eligible: false, ineligible_reason: "surface"`. The
  400/403 fallback keeps cswap's identity. Used resets (`resets_total -
  resets_left`) are listed in `usedExpirations`.

Both refuse unfamiliar source layouts and keep pristine `.before-*` copies
beside the changed files; restore those to undo. A `cswap` upgrade can replace
the patches; run `python3 Scripts/test_claude_swap_*.py`, then the installer
with the installed `site-packages/claude_swap` directory. The Swift parser
(`ClaudeLimitResetStatusResponse`) applies the same rule to the app's own OAuth
reads.

## Historical inspection

Hovering the history chart reconstructs the corners at that instant:

- Completed civil days use their latest daily totals, even when the report
  was fetched later (Codex server buckets are re-read with `tokenSnapshot()`,
  not only receipts fetched before the instant).
- The inspected day's own aggregate may contain later activity, so only
  timestamped events up to the instant count for it. Claude org events are
  grouped into 5-minute slices stamped with their latest event, preserving
  per-day totals while keeping per-render work small.
- Spend, balance, allowances and reset inventories restore the latest
  observation at or before the instant (plus a 0.5 s look-ahead so one
  refresh's separately stamped lanes line up), while that lane's next poll was
  not yet overdue: tolerance `min(5400 s, max(900 s, 3 × median cadence))`.
  Each value keeps its own observation timestamp. Hover snapping prefers
  complication observation dates over quota samples.
- No observation, no value: before a lane's first observation the corner is
  "—".
- A spend reading restores with its `isDisabled` flag, so a recorded "turned
  off" allowance stays off while hovering.
- The banked-reset corner shows the inventory observed at or before the
  instant (and when it was observed); its help names any banked reset redeemed
  in the selected period up to the instant. Window and provider resets never
  change it.

## Reset events

Every quota window that started over is typed from recorded history
(`NativeOrbitResetEvent.swift`), so past resets appear as soon as their
inputs exist. Inputs: quota lane observations (`usedPercent`, `resetsAt`;
server period totals excluded), the `nativeMetric:resets` inventory lane, and
the quota lanes of the provider's other accounts in the popup.

- **Window reset (natural)**: an observation's `resetsAt` lies after it and at
  or before the next observation (or within 120 s after a next observation that
  already shows the drop), with usage above 0 to restore. Dated at that
  `resetsAt`. A countdown that has run out before the next observation counts.
- **Early drop**: before its `resetsAt` (by more than 120 s) usage fell by at
  least 5 points to at most half. Smaller decreases (rounding, rolling
  windows) are not resets; a drop without a known schedule is not typed.
  Drops on several lanes in the same bracket are one reset.
- **Banked reset (manual)**: an early drop matched to a redemption. Codex
  credits with status `redeemed` carry `redeemedAt`: the reset is dated
  exactly. Otherwise a redemption lies between two inventory readings whose used
  resets rose (Claude `resets_total - resets_left`) or, without a used count,
  whose available resets fell other than by expiry; it is dated within that
  bracket. A redemption with no recorded quota drop is still drawn.
- **Provider reset**: an early drop with no redemption, where an inventory
  reading on each side proves nothing was redeemed, the provider has no banked
  resets (Kimi), or another account of the provider dropped in an overlapping
  bracket of at most 3 h.
- **Cause not recorded**: any other early drop, typically before the inventory
  lane existed. It is never guessed as banked or provider.

Early resets without an exact time are dated at the new window's start when
its schedule places it inside the bracket (`resetsAt` minus the window length),
else at the first reading that shows the reset; their help gives the bracket.

The chart draws each reset as a vertical rise at that instant: the last
reading before it is held to the instant (`Sample.isResetEdge` points, never
counted as observations), then the line starts from 100 % available. The rise
needs a reading on each side within the lane's gap limit (three median polling
intervals, 15 to 90 minutes) of the instant. A drop without a known schedule
has no instant and stays a break.

Inventory observations are recorded on every refresh (32-day retention), which
is all the classification needs; `PlanUtilizationHistoryEntry` is unchanged.
Codex's endpoint returned no redeemed credits for accounts that had reset
early before the inventory was recorded, so a later empty list is not treated
as proof that nothing was redeemed.

## Units, scope and attribution

Kimi request allowances are not token counts. Quota deadlines and subscription
expiry dates are not reset inventories. Allowance percentages never become
tokens, dollars or history curves. Local usage keeps its scope label
("Local sessions on this Mac" / "in this profile") and never becomes an account
total.

Attribution needs evidence in the source data:

- **Claude**: each transcript session carries a `credential_org` attachment
  (`organizationUuid`). The incremental Claude scanner tags every usage row
  with the organization active at that point in the file (sessions that switch
  organization mid-file are attributed per row) and persists the session map
  for resumed reads. Each ClaudeSwap account receives only its organization's
  rows. Rows without an attachment stay unattributed; 30D totals are labelled
  partial when attribution starts inside the window.
- **Codex**: requests in the live `~/.codex` home are attributed by the weekly
  rate-limit window (`resets_at`) on each event, matched within ±120 s to the
  windows each account recorded itself. Windows recorded by more than one
  account, or none, stay unattributed and mark their day partial. With one
  visible account, the whole-home report is used as before.
- **Kimi**: wire records carry no account identity, so they stay local-machine
  usage on the ambient row.

Third-party poll caches that replace measurement timestamps with their own
refresh time cannot establish observation times for historical import.

## Codex cost database and parser hash

`Scripts/regenerate-codex-parser-hash.sh` hashes the non-Claude, non-Store
files in `Sources/CodexBarCore/Vendored/CostUsage`. When the hash changes,
`CostUsageStore` rebuilds the Codex cost database (gigabytes of rollouts)
unless the previous hash is listed in
`CostUsageStore.compatiblePredecessorParserHashes`. The script now refuses to
write a new hash unless the previous one is listed (pass `--semantic-change`
only for a real Codex parsing change). Never remove listed predecessors. After
a rebuild, the spend-dashboard catch-up switches once to accelerated mode
(on AC power, no low-power or thermal pressure) instead of the 0.1 % duty
cycle.

## Kimi Code retained token records

Kimi Code `~/.kimi-code/sessions/<project>/<session>/agents/<agent>/wire.jsonl`
turn-level `usage.record` entries carry additive `inputOther`, `output`,
`inputCacheRead` and `inputCacheCreation` counters; native usage sums all four
and keeps the original millisecond `time`. `token_counting` and non-turn
aggregates are excluded. Complete records are deduplicated across proven copies
of the same session and agent.

The scanner stats every file, reads the most recently modified first, skips
files last written before the 32-day retention window, and reads up to 64 MiB
per pass in 4 MiB slices on its own utility queue (it no longer waits behind
Codex/Claude scans). Today's records appear in the first pass; a cold corpus
converges in a handful of passes. Archive version 3 persists per-file cursors
(always at a line boundary, never partial-line bytes) beside the events, so a
relaunch reads only appended bytes; version 2 archives migrate their events.
The retention filter runs once per pass and the archive is saved at most once
per pass. A pass that has read every file to EOF with a writable archive
establishes coverage, which labels totals complete (it does not create zeros).

Spend is an estimated list-price cost from the models.dev cache: a route model
is priced only when models.dev unambiguously identifies the underlying Moonshot
API model (`kimi-code/k3` → `kimi-k3`). Other routes stay unpriced and mark the
cost partial. Prompt text, credentials, raw root paths and raw record payloads
are never archived.

## Live inspection evidence

In debug builds launched with `--native-popup-preview-provider <provider>`, the
live popover controller writes `codexbar-native-history-<provider>.json` for
every enabled provider to the process's temporary directory on each popup
update: per-account period totals, source availability, reset/balance/spend
values, history lane counts and reconstructed readings at the first and last
observations. It contains no credentials, email addresses or account
identifiers. Normal launches do not write it.
