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

Hovering the history chart reconstructs all four at that instant. The rules
every value must obey (zero means received, no billing-cycle relabelling, scope
labels, attribution, history restore tolerance, typed resets) are in
`docs/native-history-source-contracts.md`.

### Resets on the history chart

Every reset in the selected range is drawn on the chart, typed by what reset
the window (`NativeOrbitResetEvent.swift`):

| Type | Mark | Help |
| --- | --- | --- |
| Window reset: the countdown reached `resetsAt` | the quiet dashed rule, no glyph | "Window reset" |
| Banked reset you redeemed | solid rule, `arrow.uturn.backward.circle.fill` (the bottom-leading glyph) | "Reset by you (banked reset)" |
| Provider reset: early, nothing redeemed | dashed rule, `building.2.crop.circle.fill` | "Reset by OpenAI" / "Reset by Anthropic" |
| Early reset whose cause was not recorded | dotted rule, `questionmark.circle.fill` | "Early reset · cause not recorded" |

Glyphs sit in a band above 100 % (the plot reserves it only when the range has
one). The chart's help lists each reset with its lanes and time; hovering near
a reset adds its short type to the hover time. Only banked resets change the
bottom-leading corner.

A reset is part of the quota line: the last reading holds until the reset's
instant, the line rises there to the full window (or to a reading taken at that
instant) and continues to the next reading, under the reset's mark. Hovering
before the instant reads the old window, from it on the new one. The line joins
only when readings on both sides lie within the lane's recording-gap limit of
the instant; otherwise it stays broken like any other gap.

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

## Verifying against live data

Unit tests cover the rules; only the running app proves the wiring. The
inspection hooks are opt-in launch arguments and work in release builds (the
default for `Scripts/build_native_app.sh`; `NATIVE_BUILD_CONFIGURATION=debug`
packages a debug build):

```sh
pkill -x CodexBarNative
open -n "$HOME/Applications/CodexBar Native.app" --args --native-popup-preview-provider claude
```

Add `--native-popup-benchmark` to time popup opens and history hover sweeps
on live data (`codexbar-native-popup-benchmark-<provider>.json`).

Add `--native-popup-refresh-probe` to click the popup's own refresh button
after `CODEXBAR_REFRESH_PROBE_DELAY` seconds (default 20), `CODEXBAR_REFRESH_PROBE_RUNS`
times (default 2), and record how long the spinner ran, when the background
enrichment finished, each column's update time before and after, and the
toolbar error (`codexbar-native-refresh-probe-<provider>.json`). With
`CODEXBAR_REFRESH_PROBE_SETTINGS=1` it then clicks the gear and records whether
Settings appeared. The app also logs `Native popup refresh loaded` with the
load time.

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

claude-swap serves an account reading younger than three minutes (or not yet
due by its poll plan) from its own cache to stay inside the usage endpoint's
hourly budget, so a refresh inside that window returns the same reading; the
age label then stays as it was. A load that runs past 30 s stops the spinner
and reports itself; it still publishes when it completes. A column's own
failure after a refresh turns the arrow into the orange
`exclamationmark.arrow.trianglehead.2.clockwise.rotate.90` glyph, with the
error in its help.

The app writes `$TMPDIR/codexbar-native-history-<provider>.json` for every
enabled provider on each popup update (no credentials or identities). Wait for
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
