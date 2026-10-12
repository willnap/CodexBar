import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeGaugeLifecycleTests {
    @Test func `unrelated updates retain notice events and do not replay expired pace`() throws {
        let model = NativeGaugeRenderState()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = ComputeGauge.State()
        state.pace = .fast
        model.update(state: state, accountID: "first", at: now)
        let event = try #require(model.state.paceEventAt)
        #expect(event == now)
        model.update(state: state, accountID: "first", at: now.addingTimeInterval(60))
        #expect(model.state.paceEventAt == event)
        #expect(model.renderedAt == now)
        #expect(!ComputeGauge.paceNoticeIsActive(
            pace: model.state.pace, eventAt: event, now: now.addingTimeInterval(60)))
        state.weeklyUsed = 0.7
        model.update(state: state, accountID: "first", at: now.addingTimeInterval(120))
        #expect(model.state.paceEventAt == event)
        #expect(model.renderedAt == now.addingTimeInterval(120))
        state.pace = .slow
        model.update(state: state, accountID: "first", at: now.addingTimeInterval(180))
        #expect(model.state.paceEventAt == now.addingTimeInterval(180))
    }

    @Test func `health changes replay once and a new account starts its own notice`() {
        let model = NativeGaugeRenderState()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = ComputeGauge.State()
        state.health = .authentication
        state.pace = .slow
        model.update(state: state, accountID: "first", at: now)
        model.update(state: state, accountID: "first", at: now.addingTimeInterval(60))
        #expect(model.state.healthEventAt == now)
        state.health = .live
        model.update(state: state, accountID: "first", at: now.addingTimeInterval(120))
        #expect(model.state.healthEventAt == now.addingTimeInterval(120))
        #expect(model.state.paceEventAt == now.addingTimeInterval(120))
        model.update(state: state, accountID: "second", at: now.addingTimeInterval(180))
        #expect(model.state.paceEventAt == now.addingTimeInterval(180))
    }
}
