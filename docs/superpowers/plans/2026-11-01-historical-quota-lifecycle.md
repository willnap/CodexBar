# Historical Quota Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Preserve an account's historical quota identities, labels and durations when its current quota set changes, including Claude session + weekly → weekly-only → session + weekly.

**Architecture:** Add optional per-reading quota descriptors and account-owned quota-schema receipts to the existing history format. A shared timeline distinguishes applicable, absent and unknown quotas and supplies lifecycle boundaries to charts, historical inspection, forecasts and derived activity/reset evidence. Existing data remains readable; surviving duration fragments are annotated before coalescing, while lost labels and transition times are never guessed.

**Tech Stack:** Swift 6, Foundation Codable, existing Swift Testing and SwiftUI/Charts models.

**Spec:** User request in this chat and `docs/native-history-source-contracts.md`.

## Global Constraints

- Keep history strictly scoped to its verified account/provider bucket.
- No provider probes, credential reads or real account switches; synthetic histories only.
- A removed window is not a 0% observation, reset, exhaustion or forecast.
- Coverage is explicit: only covered base quota slots can be retired by a successful base reading; optional adjuncts and unmeasurable existing windows are not silently removed.
- Unknown duration is distinct from legacy metadata that was never recorded.
- Full suite is not a foreground handoff gate; run focused suites and `make check`.
- Commit/push app to verified-private origin, install and verify optimized bundle, then back up workspace pointer/archive/receipt privately.

## Review Focus

- Removal and return inside one normal polling gap must break interpolation and derived consumption/reset evidence.
- A period or label change must survive coalescing and Codable save/load.
- Unknown measurements and partial/adjunct payloads must not retire unrelated quotas.
- Before schema coverage begins, preserve legacy evidence without invented membership boundaries.
- A retired historical lane remains inspectable in its earlier period but produces no current forecast/events.

### Task 1: Reproduce and preserve quota descriptors

Files: `PlanUtilizationHistoryStore.swift`, `UsageStore+NativeOrbitHistory.swift`, `UsageStore/UsageStore+PlanUtilization.swift`, `NativeGauge/NativeOrbitHistoryWidget.swift`; test `NativeOrbitQuotaLifecycleTests.swift`.

- [x] Add existing-API regression fixtures and observe failures.
- [x] Store an optional observed label/duration per native quota reading; decode older history without that field.
- [x] Attach surviving fragment duration metadata before coalescing and retain explicit unknown cadence.
- [x] Use observed descriptors for samples and historical labels.

### Task 2: Record and query authoritative quota membership

Files: new `NativeGauge/NativeOrbitQuotaTimeline.swift`, `NativeGauge/NativeOrbitMetricHistory.swift`, `UsageStore+NativeOrbitHistory.swift`.

- [x] Add generic schema receipts with covered IDs and present definitions in the existing native metric series.
- [x] For successful base quota responses, cover proven base slots independently from optional adjuncts; a missing utilization reading does not erase an explicitly present window.
- [x] Deduplicate unchanged daily schema receipts, preserving every transition and normal history retention.
- [x] Query membership and epoch continuity without inferring transitions from gaps.

### Task 3: Apply lifecycle semantics to consumers

Files: `NativeOrbitHistoricalInspection.swift`, `NativeOrbitHistoryWidget.swift`, `NativeOrbitProjection.swift`, `NativeOrbitResetEvent.swift`, `NativeOrbitPreparedWarningHistory.swift`.

- [x] Break chart joins and hover interpolation across lifecycle boundaries.
- [x] Restore the inspected instant's quota set and descriptors, rather than importing present-day membership.
- [x] Exclude retired quotas from future lanes and scheduled events.
- [x] Use the same boundaries for consumption and reset evidence, including countdown-tail resets.
- [x] Run focused history, persistence, projection and warning regression suites; fix all relevant failures.

### Task 4: Verify and deliver

- [x] Review final diff independently and fix substantive findings before release compilation.
- [x] Run `make check` and preserve unrelated workspace content.
- [ ] Commit/push app privately, build/install optimized app once, restart and verify signature/provenance.
- [ ] Record validation and push workspace pointer + LFS archive privately.

## Execution ledger

- Ruling: keep one stored quota timeline per logical lane and add optional per-entry descriptor metadata, rather than changing persisted series keys — existing chart/cache contracts require a stable lane identity across cadence changes.
- Ruling: distinguish a missing legacy descriptor from an observed unknown duration; label metadata is optional when annotating surviving legacy fragments — old facts cannot be reconstructed from today's metadata.
- Ruling: use covered-ID schema receipts, not synthetic zero quota readings or polling gaps — absence must be independent of utilization and optional-source coverage.
- Ruling: initial source authority is limited to proven base-slot contracts; optional adjuncts are not retired from a narrower response. Source audit is in progress before finalizing those producers.
- Preflight: clean app tree at 5f24b27706e6d810043fefe947d5c7322e87f569. Workspace has two unrelated untracked design/validation folders that must remain untouched.
- RED fixtures: durable duration changes, removed/returned quota gaps, historical membership, retired forecasts, derived reset/consumption evidence and label changes. Test build in progress; no production edits yet.
- RED result: six fixtures failed with ten expected semantic issues (duration loss, interpolation across retirement, historical membership, forecast, reset/activity and old label).
- Initial GREEN: all six fixtures passed after descriptor/lifecycle implementation.
- Ruling: carry optional live-only `UsageSnapshot.quotaWindowPresence` from actual Claude OAuth/Web payloads and healthy claude-swap rows. Raw snapshot optionals are insufficient authority: present-but-unmeasured windows and pruned cached projections otherwise falsely retire quotas. CLI/adjunct/cache reads supply no negative authority. Other producers can opt into the same contract later.
- Ruling: include explicit measurement availability in schema descriptors so a present-but-unmeasured window stays applicable while interpolation/forecast values remain unknown.
- Expanded regression run covers legacy role history, explicit unknown duration, explicit empty inventory, partial/last-known projections and producer metadata propagation/cache exclusion.

- Review fixes: raw OAuth object presence and weekly alias alignment; explicit unknown forecast cadence; descriptor preservation during owner migration; per-entry Codex transport-slot routing. Expanded source/migration regressions cover each.
- Final focused verification: 471 tests in 29 suites passed. Two old overage equality assertions were updated to include newly persisted descriptors; overage values and save/load equality remain asserted.
- Final `make check` passed (3492 Swift files, zero lint violations); focused formatting/lint passed.
- Independent review found no remaining confirmed substantive issues. An empty healthy claude-swap row remains missing usage under its existing explicit contract; it does not invent an authoritative empty inventory.
- Lost legacy cadence, labels and exact transition times cannot be reliably recreated. Existing saved observations and surviving duration fragments are retained, with no ad hoc edits to user history.
- Runtime installation, signature/provenance and private workspace backup completion are recorded in the workspace validation receipt after the source commit.
- Final boundary refinement: an accepted empty/adjunct-only JSON body previously emitted both-false base authority. A temporary reproduction compiled the actual raw OAuth response decoder with inert unrelated optional-payload types and failed before the guard. It now passes six empty/adjunct/scalar/null/object/weekly-alias cases. Full parser regressions also exercise real source types; temporary probe files were removed.
- Ruling: only recognized base keys with object/null shape establish base coverage. No recognized base evidence means unknown, including valid spend-only responses. Explicit nulls retain authoritative empty-inventory semantics.
