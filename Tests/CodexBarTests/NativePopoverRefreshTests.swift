import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativePopoverRefreshTests {
    @Test func `opening with refresh disabled starts no usage request`() async throws {
        let scheduler = NativePopoverRefreshScheduler(delay: .milliseconds(5))
        var requests = 0
        scheduler.schedule(enabled: false, isCurrent: { true }, refresh: { requests += 1 })
        try await Task.sleep(for: .milliseconds(20))
        #expect(requests == 0)
    }

    @Test func `opening twice coalesces its delayed refresh`() async throws {
        let scheduler = NativePopoverRefreshScheduler(delay: .milliseconds(5))
        var requests = 0
        scheduler.schedule(enabled: true, isCurrent: { true }, refresh: { requests += 1 })
        scheduler.schedule(enabled: true, isCurrent: { true }, refresh: { requests += 1 })
        for _ in 0..<100 {
            if requests == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(requests == 1)
    }

    @Test func `dismissal and stale selection cancel pending open refresh`() async throws {
        let scheduler = NativePopoverRefreshScheduler(delay: .milliseconds(5))
        var requests = 0
        scheduler.schedule(enabled: true, isCurrent: { true }, refresh: { requests += 1 })
        scheduler.cancel()
        scheduler.schedule(enabled: true, isCurrent: { false }, refresh: { requests += 1 })
        try await Task.sleep(for: .milliseconds(20))
        #expect(requests == 0)
    }

    @Test func `toolbar refresh stops its spinner once the columns load and enriches afterwards`() async throws {
        let refresh = NativePopoverManualRefresh(timeout: .seconds(60))
        var events: [String] = []
        var outcomes: [NativePopoverManualRefresh.Outcome] = []
        let (loadGate, openLoad) = AsyncStream<Void>.makeStream()
        let started = refresh.press(
            load: {
                events.append("load")
                for await _ in loadGate {
                    break
                }
            },
            enrich: { _ in events.append("enrich") },
            completion: { outcome in
                events.append("loaded")
                outcomes.append(outcome)
            })
        #expect(started == .started)
        #expect(refresh.isLoading)
        openLoad.yield()
        for _ in 0..<100 where events.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(events == ["load", "loaded", "enrich"])
        #expect(outcomes == [.finished])
        #expect(!refresh.isLoading)
        for _ in 0..<100 where refresh.isEnriching {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!refresh.isEnriching)
    }

    @Test func `toolbar refresh that outlives its timeout stops the spinner and says so`() async throws {
        let refresh = NativePopoverManualRefresh(timeout: .milliseconds(20))
        var outcomes: [NativePopoverManualRefresh.Outcome] = []
        var enriched = false
        let (loadGate, openLoad) = AsyncStream<Void>.makeStream()
        refresh.press(
            load: { for await _ in loadGate {
                break
            } },
            enrich: { _ in enriched = true },
            completion: { outcomes.append($0) })
        for _ in 0..<100 where outcomes.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(outcomes == [.timedOut])
        #expect(!refresh.isLoading, "A slow load never keeps the spinner running")
        openLoad.yield()
        for _ in 0..<100 where !enriched {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(enriched, "The late load still publishes and enriches")
        #expect(outcomes == [.timedOut], "A late completion does not report twice")
        let next = refresh.press(load: {}, enrich: { _ in }, completion: { _ in })
        #expect(next == .started, "A press after a timed-out load starts a fresh one")
    }

    @Test func `toolbar refresh runs one enrichment at a time`() async throws {
        let refresh = NativePopoverManualRefresh(timeout: .seconds(60))
        var enrichments = 0
        let (enrichGate, openEnrich) = AsyncStream<Void>.makeStream()
        refresh.press(
            load: {},
            enrich: { _ in
                enrichments += 1
                for await _ in enrichGate {
                    break
                }
            },
            completion: { _ in })
        for _ in 0..<100 where !refresh.isEnriching {
            try await Task.sleep(for: .milliseconds(10))
        }
        var secondLoaded = false
        let second = refresh.press(
            load: {},
            enrich: { _ in enrichments += 1 },
            completion: { _ in secondLoaded = true })
        #expect(second == .started, "Background enrichment never holds back a press")
        for _ in 0..<100 where !secondLoaded {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(secondLoaded)
        #expect(enrichments == 1, "A running enrichment covers the newer load")
        openEnrich.yield()
        for _ in 0..<100 where refresh.isEnriching {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!refresh.isEnriching)
    }

    @Test func `a later press during a load queues exactly one more load before the spinner stops`() async {
        let refresh = NativePopoverManualRefresh(timeout: .seconds(60), joinWindow: .zero)
        let gate = ManualLoadGate()
        var outcomes: [NativePopoverManualRefresh.Outcome] = []
        func press() -> NativePopoverManualRefresh.Press {
            refresh.press(load: { await gate.wait() }, enrich: { _ in }, completion: { outcomes.append($0) })
        }
        #expect(press() == .started)
        await waitUntil { gate.started == 1 }
        #expect(press() == .queued, "A press during a load is never dropped")
        #expect(press() == .queued, "Further presses share the one queued load")
        gate.openNext()
        await waitUntil { gate.started == 2 }
        #expect(refresh.isLoading, "The spinner keeps going through the queued load")
        #expect(outcomes.isEmpty)
        gate.openNext()
        await waitUntil { !refresh.isLoading }
        #expect(gate.started == 2, "Three presses during one load fetch exactly twice")
        #expect(refresh.loadCount == 2)
        #expect(outcomes == [.finished])
    }

    @Test func `a press with the click that started the load joins it without another fetch`() async {
        let refresh = NativePopoverManualRefresh(timeout: .seconds(60), joinWindow: .seconds(30))
        let gate = ManualLoadGate()
        var outcomes: [NativePopoverManualRefresh.Outcome] = []
        func press() -> NativePopoverManualRefresh.Press {
            refresh.press(load: { await gate.wait() }, enrich: { _ in }, completion: { outcomes.append($0) })
        }
        #expect(press() == .started)
        await waitUntil { gate.started == 1 }
        #expect(press() == .joined, "A double click is one request")
        gate.openNext()
        await waitUntil { !refresh.isLoading }
        #expect(gate.started == 1)
        #expect(outcomes == [.finished])
    }

    @Test func `a press during the queued load queues the next one`() async {
        let refresh = NativePopoverManualRefresh(timeout: .seconds(60), joinWindow: .zero)
        let gate = ManualLoadGate()
        func press() -> NativePopoverManualRefresh.Press {
            refresh.press(load: { await gate.wait() }, enrich: { _ in }, completion: { _ in })
        }
        #expect(press() == .started)
        await waitUntil { gate.started == 1 }
        #expect(press() == .queued)
        gate.openNext()
        await waitUntil { gate.started == 2 }
        #expect(!refresh.hasQueuedLoad, "The queued load consumed its request")
        #expect(press() == .queued, "A press during the follow-up asks for a reading after it too")
        gate.openNext()
        await waitUntil { gate.started == 3 }
        gate.openNext()
        await waitUntil { !refresh.isLoading }
        #expect(refresh.loadCount == 3)
    }

    @Test func `a queued load that hangs still stops the spinner at its own timeout`() async {
        let refresh = NativePopoverManualRefresh(timeout: .milliseconds(300), joinWindow: .zero)
        let gate = ManualLoadGate()
        var outcomes: [NativePopoverManualRefresh.Outcome] = []
        func press() -> NativePopoverManualRefresh.Press {
            refresh.press(load: { await gate.wait() }, enrich: { _ in }, completion: { outcomes.append($0) })
        }
        #expect(press() == .started)
        await waitUntil { gate.started == 1 }
        #expect(press() == .queued)
        gate.openNext()
        await waitUntil { gate.started == 2 }
        await waitUntil { !outcomes.isEmpty }
        #expect(outcomes == [.timedOut], "A spinner is never left running")
        #expect(!refresh.isLoading)
        #expect(press() == .started, "The next press after a timeout fetches again")
        gate.openNext()
        gate.openNext()
        await waitUntil { !refresh.isLoading }
    }

    @Test func `toolbar names each column its refresh could not bring up to date`() {
        let requested = Date()
        func account(_ label: String, updatedAt: Date?, claudeSwap: Bool = false) -> NativeOrbitAccountPresentation {
            // Provider-specific by design: claude-swap rows explain the adapter's own pacing.
            let selection: NativeOrbitAccountSelection = claudeSwap ? .claudeSwap(ProviderAccountUsageSnapshot(
                id: ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: "2"),
                provider: .claude,
                displayLabel: label,
                isActive: false,
                canActivate: true,
                snapshot: nil,
                error: nil,
                sourceLabel: ClaudeSwapAccountProjection.sourceLabel)) : .none
            return NativeOrbitAccountPresentation(
                id: label,
                label: label,
                email: nil,
                symbol: "person",
                isActive: false,
                canActivate: false,
                gauge: .init(),
                updatedAt: updatedAt,
                history: [],
                odometer: nil,
                odometerHelp: nil,
                statusText: nil,
                selection: selection)
        }
        let refreshIssue = NativeServicePopoverController.refreshIssue
        #expect(refreshIssue([account("Only", updatedAt: requested.addingTimeInterval(3))], requested) == nil)
        #expect(
            refreshIssue([account("Only", updatedAt: requested.addingTimeInterval(-20))], requested) == nil,
            "A reading taken moments before the load started is current")
        let stale = requested.addingTimeInterval(-600)
        let captured = L("Updated %@", NativeOrbitTooltip.moment(stale, now: Date()))
        #expect(refreshIssue([account("Only", updatedAt: stale)], requested)
            == NativeOrbitRefreshIssue(kind: .stale, detail: captured))
        #expect(
            refreshIssue([
                account("Active", updatedAt: requested.addingTimeInterval(4)),
                account("Spare", updatedAt: stale, claudeSwap: true),
            ], requested) == nil,
            "claude-swap measures an idle account every 10 minutes; within that schedule its reading is current")
        let overdue = requested.addingTimeInterval(-1200)
        let overdueCaptured = L("Updated %@", NativeOrbitTooltip.moment(overdue, now: Date()))
        #expect(refreshIssue([
            account("Active", updatedAt: requested.addingTimeInterval(4)),
            account("Spare", updatedAt: overdue, claudeSwap: true),
        ], requested) == NativeOrbitRefreshIssue(
            kind: .stale,
            detail: "Spare: \(overdueCaptured)\n\(L("native_refresh_claude_swap_paced"))"))
        #expect(
            refreshIssue([account("Only", updatedAt: stale)], nil) == nil,
            "Age alone is no failure without a press")
    }

    @Test func `toolbar error names each column that failed to refresh`() {
        func account(_ label: String, status: String?) -> NativeOrbitAccountPresentation {
            NativeOrbitAccountPresentation(
                id: label,
                label: label,
                email: nil,
                symbol: "person",
                isActive: false,
                canActivate: false,
                gauge: .init(),
                updatedAt: nil,
                history: [],
                odometer: nil,
                odometerHelp: nil,
                statusText: status,
                selection: .none)
        }
        #expect(NativeServicePopoverController.refreshIssue([account("Only", status: nil)]) == nil)
        let failed = NativeServicePopoverController.refreshIssue([account("Only", status: "Sign in required")])
        #expect(failed == NativeOrbitRefreshIssue(kind: .failed, detail: "Sign in required"))
        #expect(failed?.label == L("Failed"))
        #expect(NativeServicePopoverController.refreshIssue([
            account("Work", status: " "),
            account("Home", status: "Rate limited"),
        ]) == NativeOrbitRefreshIssue(kind: .failed, detail: "Home: Rate limited"))
    }
}

/// Holds each load until the test opens it, in order.
@MainActor
private final class ManualLoadGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = 0
    private(set) var started = 0

    func wait() async {
        self.started += 1
        guard self.opened < self.started else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func openNext() {
        self.opened += 1
        guard !self.waiters.isEmpty else { return }
        self.waiters.removeFirst().resume()
    }
}

/// Returns as soon as the condition holds; the ceiling is generous because the full suite runs in parallel.
@MainActor
private func waitUntil(timeout: Duration = .seconds(20), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
