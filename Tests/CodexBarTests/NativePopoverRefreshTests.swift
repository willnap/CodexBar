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
        let refresh = NativePopoverManualRefresh(timeout: .seconds(5))
        var events: [String] = []
        var outcomes: [NativePopoverManualRefresh.Outcome] = []
        let (loadGate, openLoad) = AsyncStream<Void>.makeStream()
        let started = refresh.start(
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
        #expect(started)
        #expect(refresh.isLoading)
        let duplicate = refresh.start(load: { events.append("second") }, enrich: { _ in }, completion: { _ in })
        #expect(!duplicate, "Presses during a load never queue another fetch")
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
        refresh.start(
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
        let next = refresh.start(load: {}, enrich: { _ in }, completion: { _ in })
        #expect(next)
    }

    @Test func `toolbar refresh runs one enrichment at a time`() async throws {
        let refresh = NativePopoverManualRefresh(timeout: .seconds(5))
        var enrichments = 0
        let (enrichGate, openEnrich) = AsyncStream<Void>.makeStream()
        refresh.start(
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
        let second = refresh.start(
            load: {},
            enrich: { _ in enrichments += 1 },
            completion: { _ in secondLoaded = true })
        #expect(second)
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
        #expect(NativeServicePopoverController.refreshError([account("Only", status: nil)]) == nil)
        #expect(NativeServicePopoverController.refreshError([account("Only", status: "Sign in required")])
            == "Sign in required")
        #expect(NativeServicePopoverController.refreshError([
            account("Work", status: " "),
            account("Home", status: "Rate limited"),
        ]) == "Home: Rate limited")
    }
}
