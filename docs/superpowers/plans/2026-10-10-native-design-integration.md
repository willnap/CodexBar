# Native design integration implementation plan

**Goal:** Connect the custom gauge design to real state, simplify native settings and preserve normal operation across refreshes and login.

**Architecture:** Retain the shared account-scoped presentation model and existing refresh policy. Add typed state/event projection, concise native preference surfaces and persistent macOS identity/access lifecycle.

**Tech Stack:** Swift 6, AppKit, Observation, ServiceManagement, native SF Symbols, macOS 26+.

**Spec:** ../specs/2026-10-10-native-design-integration.md

## Global constraints

- macOS 26+, no new dependencies, no fabricated live measurements.
- Preserve generated Revision 37 gauge artwork and provider isolation.
- Use fixture-backed tests without live credential reads or permission prompts.
- Keep the authorized installed app path and real account configuration.

## Review focus

- A failed login cannot borrow another account's authentication or usage state.
- Repeated identical updates cannot restart the same animation.
- Dismissing or switching a popup cancels its pending open refresh.
- Saved refresh/login opt-outs survive restart; missing native choices use defaults.
- Rebuilding changes code hashes but preserves certificate-backed identity.

## Tasks

- [x] Connect account-owned health and pace to gauge state. Exercise live/stale/unknown/disabled/outage/authentication transitions, pace bands, account changes and stable event times through focused failing tests. Preserve the hosting view and verify unchanged updates do not replay.
- [x] Add native preferences and style routing. Test persistence, invalid input recovery, legacy switching and native defaults through in-memory settings. Route legacy controls to existing icon/menu implementation and remove native hosts when switching.
- [x] Connect popup-open interaction to Adaptive and opt-in background refresh. Test off/on behavior, coalescing and cancellation through scheduler seams. Keep opening synchronous and prepared.
- [x] Simplify preferences and provider discovery. Show enabled providers first and verify ordering/search model with literal expected results. Replace provider images centrally and retain working legacy controls only in Legacy mode.
- [x] Preserve folder grants and signing identity. Exercise bookmark restore/stale handling without live folders; validate two different signed temporary bundles share their designated requirement. Never alter default keychain or install a trusted root.
- [x] Review integrated changes, run make test and make check, rebuild/verify package and relaunch actual production app. Record evidence and any physical verification limits.
