# Native dial complications

Each account column in the native popup has a dial with four corner
complications (`Sources/CodexBar/NativeGauge/NativeOrbitInstruments.swift`),
computed from `NativeOrbitAccountMetrics` for the selected Day / 7D / 30D range:

| Corner | Shows | Unknown when |
| --- | --- | --- |
| Top leading | Spend for the period: list-price estimate of the account's own usage, or a provider period reading whose window matches | no priced records in the period |
| Top trailing | Tokens for the period | no records in the period |
| Bottom leading | Banked resets as of the displayed instant: a filled glyph per banked reset, an outlined one per used reset; an empty inventory is one outlined glyph for every provider. Help names a banked reset you redeemed in the selected period | no inventory reading covers the instant ("—"); a provider without banked resets shows the glyph slashed |
| Bottom trailing | Additional usage (fraction of limit, or amount), else balance, else recorded credit usage. Icon: tinted while usage accrues, plain when it applies at zero, slashed when turned off or never reported | faint icon while loading, or when hovering an instant no reading covers |

The reset and rewards-card glyphs have no SF Symbols slash variant, so
`NativeOrbitSlashableGlyph` composes each slashed glyph into one template
image: the glyph, cut clear along the slash layer of `circle.slash`, with the
slash drawn in. It is then inked like any symbol. Previously a slash was laid
over a masked glyph. In a dark popover the slash took the material's vibrancy
and the masked glyph lost it, so the icon drew dark under a light slash.

Hovering the history chart reconstructs all four at that instant. The rules
every value must obey (zero means received, no billing-cycle relabelling, scope
labels, attribution, history restore tolerance, typed resets) are in
`docs/native-history-source-contracts.md`.

### Resets on the history chart

Every reset in the selected range is drawn on the chart, typed by what reset
the window (`NativeOrbitResetEvent.swift`):

| Type | Mark | Help |
| --- | --- | --- |
| Window reset: the countdown reached `resetsAt` | faint hairline rule, no glyph (a planned reset) | "Window reset" |
| Banked reset you redeemed | solid rule, `arrow.uturn.backward.circle.fill` (the bottom-leading glyph) | "Reset by you (banked reset)" |
| Provider reset: early, nothing redeemed | solid rule, `building.2.crop.circle.fill` | "Reset by OpenAI" / "Reset by Anthropic" |
| Early reset whose cause was not recorded | lighter rule, `questionmark.circle.fill` | "Early reset · cause not recorded" |

Recorded reset rules are always solid (dashes mean projected); weight, opacity
and glyph tell the kinds apart. Only resets that broke the window's schedule
carry a glyph, riding on the rule just above the plot's floor on a knockout
disc, so the plot never grows to make room for it.
The chart's help lists each reset with its lanes and time. Only banked resets
change the bottom-leading corner.

A reset is part of the quota line: the last reading holds until the reset's
instant, the line rises there to the full window (or to a reading taken at that
instant) and continues to the next reading, under the reset's mark. Hovering
before the instant reads the old window, from it on the new one. The line joins
only when readings on both sides lie within the lane's recording-gap limit of
the instant; otherwise it stays broken like any other gap. The limit is three
times the lane's median polling interval, never less than 45 minutes (the
slowest regular refresh, 30 min, with room for jitter) and never more than 90,
so an idle stretch polled every 30 minutes stays one line rather than a run of
lone readings, while a missed refresh still breaks it.

## Sources per provider

| Provider | Tokens / spend | Resets | Extra usage / balance |
| --- | --- | --- | --- |
| Claude (ClaudeSwap accounts) | Claude Code transcripts on this Mac, attributed per row to the account's organization via `credential_org` attachments; priced from the models.dev cache | claude-swap `resetCredits` (eligible accounts with a received grants list) | claude-swap typed monthly spend; "Off" when disabled |
| Codex (reconciled accounts) | Server daily buckets per account, merged per civil day (max) with local `~/.codex` requests attributed by weekly rate-limit window; spend = list-price estimate of attributed requests | Codex reset-credit inventory | Codex credits balance / additional usage |
| Kimi (ambient account) | `~/.kimi-code` wire `usage.record` turns (machine scope); spend estimated where models.dev identifies the route | not applicable (no such concept): slashed glyph | booster wallet monthly usage |
| Other providers | Typed provider reports, plugin reports, or background cost-scan caches (labelled "this Mac" when machine-scoped) | where the provider publishes an inventory | typed spend, balances (including non-money credit units shown in their own unit) |

Saved token-account rows only receive a cached cost-scan report when the
report's credential fingerprint matches that account's own token
(`NativeOrbitCachedUsageReport.swift`). Provider balances that exist only as
display text (Hyper, Linkup, Nous, QwenCloud, Sakana, TinyApi, V0, Zai,
SailResearch, Moonshot, DevPass, Exa) and Windsurf flex credits, StepFun mixed
credit buckets and Copilot AI credits are not yet surfaced.

## Projection

While any account in a popup is in use (a quota reading rose inside its window,
or dated usage was recorded recently; `NativeOrbitActivity`), every chart in
that popup centers **now** and plots the predicted future to its right
(`NativeOrbitChartAxis.projectingBounds`). Both edges sit the range's full span
(Day 24 h, Week 7 d, Month 30 d) either side of now, rounded to the nearest
hour, so the past and future halves are always equal. Idle popups keep the
calendar range (Day from midnight) with now at the right edge. Pace for tokens
and spend still uses the calendar period's start.

- Each quota lane continues from its latest reading at the window's pace (the
  menu's `UsagePace` rate, or the window's own trend early on), holds at
  exhaustion until the scheduled reset, rises to 100 % at the reset, and fills
  again at the same pace; idle accounts project flat. Projected lines are grey,
  light and dashed over a light grey wash, with no caption: the future half
  says it is a prediction by going progressively out of focus, sharp at now
  and blurring on an ease-in curve (3.2 pt at the end of Day's span, radius
  ∝ distance^1.6, cross-faded in thirds) (`NativeOrbitProgressiveBlur`); Week
  blurs 1.25× and Month 1.5× as hard. The blur draws
  into a canvas three times its largest radius larger than the chart, so it
  softens past the chart's edge instead of stopping at it. Dashes and blur are reserved for projections: recorded lanes
  and recorded reset rules are always solid and sharp, told apart by color,
  weight and glyph.
- Resets that broke the schedule have a glyph on their rule inside the plot:
  the dial's banked-reset glyph for one you redeemed, a building for a
  provider reset, a question mark when the cause was not recorded. Planned
  window resets, recorded or scheduled ahead, have only their faint rule.
- Time labels under the chart, all 10 pt, align to the plot edges (left label
  leading, right label trailing, now centered while projecting) and drop ":00"
  on whole hours. The projecting day reads "Yesterday", "Now", "Tomorrow"
  rather than the same hour twice; Week and Month show dates. Light vertical
  rules mark the halfway points between the labels (while idle, the middle
  label). Labels for those points do not fit beside "Yesterday" and
  "Tomorrow" in a 196 pt plot, so they stay unlabelled; the pill gives exact
  times. "Now" takes the now line's accent and weight, greying while another
  instant is inspected.
- The inspected instant appears in a Liquid Glass pill over the separator
  between the dial and the chart, drawn in front of both, with 12 pt of clear
  space above the plot for it: "Today at 3:42 PM" (or Yesterday / Tomorrow)
  near now, otherwise "Mon, Oct 6, 3:42 PM"; minutes, never seconds. On a
  reset or scheduled event the pill names the mark instead, with its glyph and
  a short time: "Reset by Anthropic 3:42 PM", "Weekly reset Mon 3:00 PM",
  "Banked reset expires Oct 20" (`NativeOrbitMarkedEvent`, matched within one
  plot point). Hovering snaps onto recorded resets as it does onto dial
  readings and scheduled events; a dial reading beside a reset still wins the
  snap, and the pill names the reset from there. The chart itself has no
  tooltip; VoiceOver reads each lane's value and each reset rule's label.
- Scheduled events ahead (window resets, banked reset expiries, the additional
  usage cycle, plan expiry) are drawn as future-styled marks.
- Now is always marked, projecting or not (idle, at the right edge): a thick
  accent line with a dot on each lane's current reading (its latest
  measurement carried to now, or the projection's value there), each dot on a
  halo of the window colour so it reads against the same-coloured line. Hovering springs it,
  with its dots, to the pointer and leaves a dim neutral line at now; it
  springs back when the pointer leaves. Ahead of now the hover line
  and its projected dots blur with the projection they read.
- Hovering the future sets a future inspection instant: rings show each window's
  predicted use, tokens and spend extend the period's pace to that instant,
  and banked resets drop by expiries before it. The dial softens with
  distance ahead on the same curve as the chart (80 % of its radius): rings,
  ring labels and corner readings together, the provider and account marks in
  the middle only lightly (35 %), since they show no data. No ring is drawn
  around the dial while inspecting.
- The gauges' colour tells time implicitly: the past mutes the rings and the
  future intensifies them, each with a clear step on crossing now and the rest
  by distance across the chart (`temporalOffset`, in tenths). Only the gauges
  shift. The chart, the corners and the rest of the column keep the column's
  own accent. The past loses 16 % of its saturation on crossing and at most
  38 % at the chart's start, keeping its hue so lanes stay distinguishable. Hovering the past reads every ring
  and corner of every column at that instant, back to the projecting chart's
  start (this time yesterday on Day); the ring lookup previously stopped at
  midnight, blanking the rings over the left of the chart.
- Projections are computed once per presentation refresh and cached with the
  chart lanes and their marked events, so hovering only evaluates them.
- Switching Day, Week and Month zooms identical marks: every range draws 31
  days of history and projects 31 days ahead (`dataDays`, clipped to the plot
  with 4 pt of slack for edge dots), so only the visible window animates.
  Window-reset rules are still thinned by the selected range. A recorded
  line's chart series is named by the first reading of its unbroken run
  (`Sample.seriesOrigin`), projected points by instant and order, and the two
  layers share one set of animations. A reset's two edges share an instant in
  the data but the held edge is drawn 30 s earlier (`renderDate`): Charts
  orders a line's points by x, and floating-point noise mid-animation used to
  swap the pair, turning rises into drops (square waves in the projection,
  wedges in the history fill). Verified frame by frame with
  `CODEXBAR_PREVIEW_ANIMATION_SCALE=25` and `CODEXBAR_PREVIEW_SWITCH_DAYS=7`
  (preview only).

## Tooltips

One plain line that says what the hovered thing means, two at most: the exact
figure the face rounds, what it covers, and the one caveat that changes how to
read it (`NativeOrbitTooltip`). No metadata chains, internal terms, seconds,
years or time zones. Moments read "3:42 PM" on the same day, "Tue 3:42 PM"
within a week and "Oct 20" beyond.

| Element | Example |
| --- | --- |
| Spend corner | "About $255.54 spent today on this Mac, at list prices"; "At least …" for a recorded subtotal; "No spend data for today" |
| Token corner | "773,812,345 tokens in the last 7 days"; "Used today, but no token count has arrived yet" when quota rose without a report |
| Banked resets | "2 banked resets available, 1 used" / "Next expires at 3:42 PM" or "Last used at 3:42 PM"; "Kimi has no banked resets" |
| Additional usage | "$12.40 of $50 additional usage this month" / "Your share: $3.20"; "Additional usage is off" |
| Ahead of now | "About 1,234,567 tokens today by 6:00 PM, at the current pace" |
| Ring | "Weekly limit: 24% left"; countdown "Weekly limit resets Mon 3:00 PM, in 4d 3h" |
| Refresh age | "Updated 1:23 PM" |

Empty ring tracks are drawn at 7.5 % (usage) and 5.5 % (countdown) of the
primary color, so a filled ring stands out even in a secondary account's
muted accent.

## Rolling digits

The spend and token corners change with SwiftUI's numeric text transition
(`.contentTransition(.numericText(value:))`), the animation Apple uses for
money and counters. Only the characters that change animate. Each changed
digit rolls up with a blur as the value grows, and down as it shrinks.
Unchanged characters stay put, since both corner fonts use tabular figures.

- **On the arc.** Each readout is one `Text`. `NativeOrbitArcTextRenderer`
  (a `TextRenderer`) places every glyph along the corner's arc: centred where
  its advance falls on the line, scaled to fit, upright to the arc, with the
  middle of its cap height on the circle. Apple's transition runs unchanged
  inside it.
- **Direction** comes from the caller's number when given, else from the
  readout's own (compact suffixes included, so "276.7M" to "1.2B" rolls up).
  "—" counts as zero, so a value appearing rolls up and one vanishing rolls
  down.
- **Scrubbing.** Changes less than 0.25 s apart come from hovering the chart,
  and show at once, as Stocks and Weather update a scrubbed readout. A
  transition at every step leaves the changing digits a permanent blur.
  Discrete changes roll: entering or leaving the chart after a pause, a
  refresh, a range switch.
- **Reduce Motion** uses a short ease instead of the smooth curve.

An earlier version (in `f40d12b`) drew each glyph as a bent outline and
rolled it through a fading window. It is replaced by the system transition.

## Hover performance

The chart's marks live in an equatable `NativeOrbitStaticPlot` keyed by the
data, the range and the column's accent, so hovering redraws only the marker,
the pill and the dial. The chart keeps the column's live accent while
hovering. The gauges' hovered-moment accent (`temporalAccent`) is a dynamic
colour, which compares equal only to itself. It is therefore made once per
tenth of offset and reused, so the rings repaint only when that tenth changes.
When the chart took a fresh hovered accent on each step, every chart mark was
redrawn on every pointer move: about 1,000 Swift Charts rebuilds per sweep,
about 140 ms per step.

## Instant dials at launch

Each provider's last published per-account dial inputs are persisted
(`native-last-known-usage/<provider>.json`, see the contracts doc) and loaded at
launch under the same ownership checks as live data, so dials are populated
within seconds and update in place when fresh scans publish. Measured on
2026-10-13 (release build): Kimi within 2 s, Claude and Codex within 5 s,
previously 30–60 s.

### First open

The popup's first frame is complete or not shown. Its columns stay hidden,
in a popup already sized for the column count it last showed (remembered per
provider), until it has everything they draw: the provider's history in
memory, its account list (for Claude, claude-swap's answer when it owns the
columns) and a reading or a definite status for every column
(`nativePopupIsReady`). Then the columns and the refresh age fade in
together, so nothing appears half drawn and nothing moves or resizes as data
lands. Five seconds after launch it shows whatever it has. Measured on the
release build: Codex ready at about 1.2 s after launch, Claude about 3.5 s,
Kimi about 4.3 s (its first reading).

What makes the inputs arrive sooner:
- Codex builds its account list from its local account files when the popup
  is prepared (`prepareNativeAccountInventory`) instead of waiting for the
  first background reconciliation.
- History decodes every provider's file concurrently and publishes each as it
  lands (`loadAsync(reporting:)`), so Claude's half-megabyte file no longer
  waits behind Codex's nine; display reads use a provider's history as soon as
  it is in memory (`nativeHistoryAvailable`), while writes still wait for every
  file (`planUtilizationHistoryLoaded`).
- claude-swap's list no longer waits for its `--version` probe (which only
  labels Settings and stalled for seconds at launch); the probe runs right
  after the list publishes. The first provider refresh joins the list the
  provider started at launch instead of restarting it, unless an account
  switch is in progress.
- claude-swap rows cannot be cached between launches: their labels, emails
  and organizations are never persisted.

## Codex usage today on another device

When a Codex account is used off this Mac, no source this app can read has
today's tokens yet: the account's local sessions hold nothing for today,
`wham/profiles/me` publishes daily buckets once a day (its lifetime total
equals their sum), and `wham/usage/daily-token-usage-breakdown` (the Codex
analytics report) returns only per-surface percentages for personal plans,
with today at 0. The quota is the only live signal; until a report arrives,
the corners read "—" with "Used today, but no token count has arrived yet".
Cloud tasks expose per-thread usage (`wham/usage/thread_usage/query`), which
could cover usage started there.

## Verifying against live data

Unit tests cover the rules; only the running app proves the wiring. The
inspection hooks are opt-in launch arguments and work in release builds (the
default for `Scripts/build_native_app.sh`; `NATIVE_BUILD_CONFIGURATION=debug`
packages a debug build):

```sh
pkill -x CodexBar
open -n /Applications/CodexBar.app --args --native-popup-preview-provider claude
```

Add `--native-popup-benchmark` to time popup opens and history hover sweeps
on live data (`codexbar-native-popup-benchmark-<provider>.json`).

The preview's "Live usage" inspection window draws on the popover's own
material, so vibrant styles render there as in the popover.
`CODEXBAR_PREVIEW_APPEARANCE=light` or `dark` forces one appearance whatever
the system's.

Set `CODEXBAR_PREVIEW_SCRUB=-12,8` (hours from now) to sweep the inspected
instant across the chart at pointer rate 45 s after launch, then reverse a
third of the way back. Each step's main-thread time lands in
`codexbar-preview-scrub.txt`. While it runs, the proof dumps are skipped,
because they would dominate the main thread. Pair it with
`CODEXBAR_PREVIEW_ANIMATION_SCALE`, which also slows the rolls, and
`screencapture -l <window>` on the "Live usage" inspection window to read the
corners frame by frame.

Add `--native-popup-refresh-probe` to click the popup's own refresh button on
live data (`NativeOrbitRefreshProbe`) after `CODEXBAR_REFRESH_PROBE_DELAY`
seconds (default 20). It records how long the spinner ran, when the background
enrichment finished, each column's update time before and after, the toolbar
error and why a click did or did not land
(`codexbar-native-refresh-probe-<provider>.json`). Phases, each off unless set:
`CODEXBAR_REFRESH_PROBE_OBSERVE` seconds sampling every flag that could make a
press inert, `CODEXBAR_REFRESH_PROBE_RUNS` idle presses (default 2),
`CODEXBAR_REFRESH_PROBE_BUSY_RUNS` presses during the timer's background
refresh, and `CODEXBAR_REFRESH_PROBE_DOUBLE_RUNS` second presses 300 ms or
1.2 s into a load. It reopens the popup if a click elsewhere closed it. With
`CODEXBAR_REFRESH_PROBE_SETTINGS=1` it then clicks the gear and records whether
Settings appeared. The app logs `Native popup refresh pressed` (started,
joined or queued), `Native popup refresh loaded` (load time, whether it
replaced a background refresh, and Claude ownership flags without identities)
and `Native popup focus`.

### Toolbar refresh

The toolbar's refresh loads only what the columns show, then returns the
spinner: each provider's usage fetch (every Codex account; the Kimi or token
accounts), or, while ClaudeSwap owns the Claude columns, the claude-swap
account list. Status, token-history scans, Codex credits and the ambient
Claude reading follow in the background without the spinner. Before this, the
spinner tracked the ambient Claude fetch, which with an expired Claude Code
login spent about 19 s on a delegated token refresh that fails and 8 s on a
CLI scrape (about 30 s in all) and never changed the ClaudeSwap columns; the
whole action then held further clicks for about 45 s. Measured on the debug
build: Claude 0.2–0.3 s, Kimi 1.5–3.5 s, Codex 4–6 s (under parallel builds).

Every press counts (`NativePopoverManualRefresh`). A press always fetches
anew: it replaces a background request in flight rather than joining one that
began before it, and if a newer request (a settings change, an account
switch) replaces the press's, the spinner follows that one to its
publication. A second press within 1 s of a load's start (a double click)
joins it; a later one joins visibly and queues exactly one more load, however
many presses arrive. Each load gets its own 30 s timeout, after which the
spinner stops and reports itself; the load still publishes when it completes.
Before this, presses during a load were silently dropped.

claude-swap serves an account reading younger than three minutes (or not yet
due by its poll plan, about 3–5 min for the active account and 10 min for an
idle one) from its own cache to stay inside the usage endpoint's hourly
budget, so a press inside that window returns the same reading. The active
account is measured on demand by the ambient Claude fetch, which joins the
load whenever its reading owns that column: one active claude-swap row owning
the login, the same unique email, and the same organization. Claude names a
personal account's organization after its email ("name@example.com's
Organization") and the CLI scrape drops such a name, so a named personal
organization and none compare as the same owner; any other organization must
match exactly (`nativeOrbitClaudeOwnerOrganization`). Before this, every
personal account failed that comparison, so a press never refreshed the
active Claude column.

A press that leaves a column behind turns the arrow into the orange
`exclamationmark.arrow.trianglehead.2.clockwise.rotate.90` glyph and adds one
orange word to the age ("5m ago · Stale"; a single column keeps the word and
drops the age first), with the full account in the help of both
(`NativeOrbitRefreshIssue`):

| Word | When | Help |
| --- | --- | --- |
| Failed | a column's own fetch reported an error | that error, per column |
| Stale | a column's reading is over a minute older than the press; for claude-swap rows, older than its 10-minute idle schedule plus jitter (12 min) | "Showing last known usage from …", with claude-swap's pacing named for its rows |
| Slow | the load ran past 30 s | it continues in the background |

A failure outranks a stale column. The word and glyph clear once a newer
reading arrives.

The app writes `$TMPDIR/codexbar-native-history-<provider>.json` for every
enabled provider on each popup update (no credentials or identities). Each
account row includes `ringReadings`, the rings as hovering shows them at fixed
offsets past and ahead of now; the Codex file adds `codexAttribution`, the
session-window attribution's inputs and outcome as counts and relative times.
`CODEXBAR_PREVIEW_INSPECT_AT=<seconds since 1970>` holds that inspected instant
12 s after launch, for captures of hover states (a pointer over the window
overrides it). The files also carry the launch timeline (`secondsSinceLaunch`,
`popupReady`, `providerHistoryAvailable`, claude-swap's list timeline) for
first-frame measurements. Wait for
background scans to settle (a few minutes after a migration) before reading it.

Compare against an independent oracle computed straight from the raw sources,
at the dump's `capturedAt`:

- Claude: parse `~/.claude/projects/**/*.jsonl` (plus claude-swap session
  profiles and Claude Desktop project stores), track the session → organization
  map from `credential_org` attachments in file order, take assistant
  `message.usage` rows, dedupe by `message.id + requestId` keeping the final
  complete chunk, bucket by Europe/London day, price with the models.dev cache.
- Codex: sum `token_usage_record` per `response_id` (else `token_count`
  `last_token_usage`) from rollouts, attribute each to the account whose weekly
  window `resets_at` it carries, price with the app's table.
- Kimi: sum the four counters of `usage.record` / `usageScope: turn` entries in
  `~/.kimi-code/sessions/*/*/agents/*/wire.jsonl`.

## 2026-10-12: complications repair

Before this work the dials were empty or wrong for every enabled provider:
both Claude accounts showed no tokens, spend, resets or history; Codex spend had
disappeared; Kimi tokens were a small, slowly growing fraction of the real total.
Root causes, each confirmed against the live app and an oracle:

- **Claude per-account usage never published.** The organization reader
  re-parsed the whole transcript corpus once per organization on every refresh;
  each ClaudeSwap refresh cancelled it and the error was swallowed. Organization
  attribution now happens inside the existing incremental, disk-cached Claude
  scan (`CostUsageScanner+ClaudeOrganizations.swift`); per-account reports are
  built from cached rows by one coalesced task. The JSONL tail scanner gained a
  `memchr` fast path (about 4.7x faster in debug). The organization archive
  stores final daily totals (`daily-v2.json`, 400 days) instead of the newest
  100k streaming chunks.
- **Codex spend vanished.** Adding `Hashable` to Claude-only types in a hashed
  vendored file changed the Codex parser hash, which deleted and rebuilt the
  multi-gigabyte Codex cost database, with catch-up at a 0.1 % duty cycle.
  Predecessor hashes are now adopted, the hash script refuses unlisted changes,
  and a rebuilt store catches up once in accelerated mode.
- **Codex costs landed on the wrong account.** Managed account homes hold no
  rollouts; all sessions live in `~/.codex`. Requests are now attributed per
  account by weekly rate-limit window. An empty home is never cost evidence.
- **Codex history and today's tokens.** Hover used only receipts fetched before
  the instant (all fetched today), and today's server bucket lags about 12 h.
  History now uses the latest completed-day buckets; each day takes the larger
  of server and attributed local tokens.
- **Kimi scan throughput.** 8 MiB passes in path order over the whole corpus
  took about 100 passes (about 11 minutes) after every launch, with no persisted
  cursors. See the Kimi section of the contracts doc for the new scanner.
- **Spend corner relabelled monthly extra usage as period spend**, showing
  "$0.00" for disabled extra usage on every range.
- **History restore required exact timestamp equality**, so lanes stamped
  microseconds apart within one refresh never restored together.
- **Zero versus unknown.** A covered period with no activity reads 0; only a
  period without data coverage reads "—" (see "Zero, unknown and not
  applicable"). Reset observations recorded as 0 for ineligible accounts by an
  interim build on 2026-10-12 were removed from Claude history.

Also finished from the previous session: OpenRouter coverage window bounds,
Command Code monthly spend and balance, Mistral wallet balance, MiMo local
token reports, cost-scan reports for Bedrock, Cursor, Antigravity, Muse, Pi and
Vertex AI, credit-unit balances for Warp, Augment, JetBrains and Venice, and
the Ollama wallet.

Verification on 2026-10-12 (debug build, live data): Claude per-account
tokens and estimated spend matched the transcript oracle within about 0.1 %;
Codex per-account spend matched the rollout oracle to the cent; Kimi tokens and
turn counts matched the wire oracle exactly; every remaining "—" was a period
with no activity or an inventory the provider does not report.

### One-time work after upgrading

- Claude: `claude-history-v7.json` is built once by a full transcript parse
  (minutes in a debug build); the legacy v6 history files and chunk archives
  are removed afterwards. `claude-v6.json` is reused.
- Codex: the existing cost database is adopted; an incomplete store runs one
  accelerated catch-up (AC power, no thermal or low-power pressure). The
  attribution timeline is rebuilt from rollouts in the background; values are
  labelled partial until then.
- Kimi: archive v2 migrates to v3 and builds file cursors; today's data is
  complete after the first pass.

### Typed resets and icon states (2026-10-12)

Reset types are derived from history the app already records: quota lanes
(`usedPercent`, `resetsAt` per observation) and the `nativeMetric:resets`
inventory lane (available and used resets, Codex `redeemedAt`). No history
schema change was needed. On the live history (copied, read-only) this found:
Claude and Kimi session windows resetting on schedule; one provider reset on
both Codex accounts in the same half hour on Oct 11 ("Reset by OpenAI"); and
four earlier Codex resets from before the inventory lane existed, which stay
"cause not recorded". Both ClaudeSwap accounts show 0 banked and 1 used reset
(one outlined glyph), both Codex accounts 0 and 0 (the same glyph, previously
the text "0"), Kimi the slashed glyph. Hover restored Claude's extra usage as
enabled at $0 because a recorded "turned off" reading lost `isDisabled`; it now
restores as turned off (slashed icon).

### Known caveats

- Codex server buckets are UTC days while local days use the configured zone,
  so the per-day maximum can shift by up to an hour around midnight.
- `codex-auto-review` and some Kimi route models have no list price, so those
  spend totals are labelled recorded subtotals.
- Transcripts written before Claude Code recorded organization attachments
  stay unattributed; a 30D total that reaches back before the first attachment
  is labelled partial.
- The installed claude-swap package carries two patches (see the contracts
  doc); a `cswap` upgrade removes them.
- An ineligible Claude account (`cedar_ember` `eligible: false`) is dropped by
  the claude-swap patch and the OAuth parser, so its reset corner reads "—"
  rather than the slashed glyph until the source carries the flag.
