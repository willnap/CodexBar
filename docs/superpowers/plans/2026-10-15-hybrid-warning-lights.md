# Hybrid warning lights implementation plan

**Goal:** Ship all 51 catalogue warnings in the native dial with stable semantic positions, active-light padding, natural 13 pt symbols and genuine extended-range emission.

**Design:** The user's hybrid design is the brief: fixed preferred neighbourhoods, scaled to available inner radius; active neighbours repel through padding without changing the dial or symbol size. The native identity marks and ring artwork remain protected. A deterministic bounded solver minimises movement and preserves category focus. Actual signals are account/provider scoped and clear when their observed condition resolves. Unknown facts never become warnings merely to fill the catalogue. HDR requires floating-point source values above SDR white and an EDR-enabled layer, with a usable SDR fallback.

**Architecture:** Existing warning enum/store pipeline expands to the exact 51 design keys. Layout is a pure active-set calculation using measured natural symbol bounds. Visible glyphs render on an extended-linear float16 surface; accessible native hit targets retain actions and tooltips. Real producer hooks feed the store; pure evaluators permit offline condition and clearing tests.

**Constraints:** Swift 6/macOS 26; existing SwiftPM dependencies only; no account mixing, no live account/Keychain/browser probes during checks, no font shrinking, hiding, shared slots or changed ring sizes. All-51 stress views accompany realistic multi-light views across one, two and three rings. Dense impossible-to-separate active sets must keep all symbols represented and report residual overlap honestly.

**Review focus:** Cached successes must not clear fetch failures; inactive-account information must not bleed from the live account; missing telemetry must not invent incidents; unavailable EDR must clamp cleanly; reordered warning inputs must not change placement; exhausted stress layouts must terminate without moving glyphs into the rings or identity.

- [x] Expand the catalogue and typed fetch classifications, with trigger/clear coverage for all 51.
- [x] Trace and connect account/history/plan/cost/system producer facts through the live store.
- [x] Write layout regressions for collision separation, stable lone anchors, all sizes, bounds, marks and input order.
- [x] Implement ideal positions and deterministic active-set padding with measured 13 pt glyph geometry.
- [x] Implement and test actual extended-linear float16 pixel emission plus EDR surface/SDR fallback.
- [x] Integrate native rendering, interaction and 51-light bulb check.
- [x] Produce native synthetic render proofs for all three sizes and all-51 stress views, with no account access.
- [x] Run focused tests, make test and make check; fix failures and report any external verification limits.

Verification: final isolated layout/HDR regressions pass (24 tests in two suites). The coordinated full make test passes all 157 groups on the first attempt, with 1,755 selections and 15,335 verified test methods; no retries or timeouts. Full make check passes with zero violations across 3,147 files. The native proof shows all 51 at all sizes, fixed identity artwork and centred money. The three-ring all-on view retains the documented overlap; normal active sets use local spacing. See Validation/Warning Light Packing/Hybrid Native/VERIFICATION.md and repository-test-summary.txt.


## Even-spacing follow-up

- [x] Replace near-shared homes with a uniformly spaced category map.
- [x] Resolve actual-size glyph padding locally instead of scaling worst-case spacing decisions.
- [x] Use actual fixed identity frames, strict-first clearance, exact glyph-edge candidates and joint neighbour separation.
- [x] Use one consistent layout energy and symmetric refinement offsets.
- [x] Add and pass even-spacing, actual-frame and crowded medium-size regressions (29 focused tests total).
- [x] Rebuild/inspect all-51 native proof and replace stale outline/black-panel HTML preview.
- [x] Confirm fresh shared gates and installed-main rebuild on the final frozen source. All157groups covered after corrected architecture retry/continuation; makecheck3150files clean; signed installed release verified and normal app running. See the final receipts for the initial command exit1 and subsequent passing26-group continuation.

Current proof and verification: Validation/Warning Light Packing/Hybrid Native/VERIFICATION.md. The old full-suite receipt above predates this follow-up.


## Interaction and lifecycle follow-up

- [x] Replace invisible SwiftUI interaction overlays with native buttons and one deterministic nearest-icon rule for clicks and tooltips.
- [x] Give all 51 kinds distinct explanations and meaningful actions, with live account/condition text and destination fallbacks.
- [x] Wire account identity through both the popup and inspection-window handlers; reject removed accounts and obsolete controls.
- [x] Verify all 51 targets at each ring count; inspect actual three-ring explanation clicks and live synthetic reading updates with all lights enabled.
- [x] Reproduce and fix retired request mutations, status failure after checks are disabled, and spend-cap warnings after extra usage is disabled.
- [x] Run fresh make check: zero violations across 3,153 files.
- [x] Complete fresh full-suite attempts/recovery and install the verified Release bundle. Warning suites pass; the full repository retains five separate palette assertions and six widget OCR errors, recorded by name in the interaction receipt.

The isolated native interaction/layout/HDR run passed 38 tests in three suites; the first integrated run passed 70 tests in seven suites. The initial full-suite attempt stopped on disk exhaustion (exit 120 from the runner, make exit 2); the low-concurrency retry also hit ENOSPC, and no-build continuations completed coverage of all 157 groups. The full suite is not green: 154 groups pass; separate palette and OCR failures remain documented. See Validation/Warning Light Packing/Hybrid Native/INTERACTION-VERIFICATION.md for final receipts.
