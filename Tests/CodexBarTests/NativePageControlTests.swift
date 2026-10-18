import Foundation
import Testing
@testable import CodexBar

struct NativePageControlTests {
    @Test func `inserting an earlier account repositions the selected stable identity`() {
        var navigation = NativePageControlNavigation(selectionID: "later-provider:account")
        navigation.inventoryChanged(
            validIDs: ["overview", "earlier-provider:old", "earlier-provider:new", "later-provider:account"],
            fallbackID: "earlier-provider:old")
        #expect(navigation.selectionID == "later-provider:account")
        #expect(navigation.request?.id == "later-provider:account")
        #expect(navigation.request?.interaction == .continuous)
    }

    @Test func `interrupting navigation reconciles a visible page even when its scroll ID never changes`() {
        let ids = ["4", "5", "6"]
        var navigation = NativePageControlNavigation(selectionID: "4")
        navigation.select("6", interaction: .discrete)
        navigation.observe("4", validIDs: ids)
        #expect(navigation.selectionID == "6")
        navigation.interrupt(at: "4", validIDs: ids)
        #expect(navigation.selectionID == "4")
        #expect(navigation.request == nil)
        navigation.settle(at: "4", validIDs: ids)
        #expect(navigation.selectionID == "4")
    }

    @Test func `interruption during a cleared native target adopts the last resolved visible page`() {
        var navigation = NativePageControlNavigation(selectionID: "4")
        navigation.select("6", interaction: .discrete)
        navigation.observe("5", validIDs: ["4", "5", "6"])
        #expect(navigation.selectionID == "6")
        navigation.interrupt(at: nil, validIDs: ["4", "5", "6"])
        #expect(navigation.selectionID == "5")
        #expect(navigation.request == nil)
    }

    @Test func `settled navigation clears its request and repeated destinations create a fresh request`() {
        var navigation = NativePageControlNavigation(selectionID: "4")
        navigation.select("6", interaction: .discrete)
        let first = navigation.request
        navigation.select("6", interaction: .discrete)
        #expect(navigation.request != first)
        navigation.settle(at: "6", validIDs: ["4", "6"])
        #expect(navigation.selectionID == "6")
        #expect(navigation.request == nil)
    }

    @Test func `custom symbol overflow reproduces the native quantized viewport and edge scales`() {
        let widths: [CGFloat] = [12.5, 13, 15.5, 15, 13, 11.5, 12.5, 13]
        let layout = NativePageControlLayout(
            count: 30,
            selection: 15,
            availableLength: 240,
            symbolWidths: (0..<30).map { widths[$0 % widths.count] })
        #expect(layout.length == 236.5)
        #expect(layout.start == 2)
        #expect(layout.offset == 167.5)
        #expect(layout.position(of: 15) == 174)
        #expect(layout.marks.first { $0.index == 8 }?.scale == 0.44609)
        #expect(layout.marks.first { $0.index == 9 }?.scale == 0.75877)
        #expect(layout.marks.first { $0.index == 16 }?.scale == 0.75877)
        let uniform = NativePageControlLayout(
            count: 30,
            selection: 15,
            availableLength: 240,
            symbolWidths: Array(repeating: 15.5, count: 30))
        #expect(uniform.length == 231.5)
        #expect(uniform.offset == 211.5)
        #expect(uniform.position(of: 15) == 167.5)
    }

    @Test func `raster badges are bounded without distorting their aspect ratio`() {
        let size = NativePageControlImageMetrics.size(
            CGSize(width: 128, height: 64),
            alignmentWidth: 128,
            isSymbol: false)
        #expect(size == CGSize(width: 14, height: 7))
        let symbol = NativePageControlImageMetrics.size(
            CGSize(width: 16, height: 13),
            alignmentWidth: 15.5,
            isSymbol: true)
        #expect(symbol == CGSize(width: 15.5, height: 13))
    }

    @Test func `vertical spacing follows symbol heights rather than widths`() {
        let size = CGSize(width: 15.5, height: 13)
        #expect(NativePageControlImageMetrics.length(size, vertical: false) == 15.5)
        #expect(NativePageControlImageMetrics.length(size, vertical: true) == 13)
    }

    @Test func `custom symbols retain the native measured widths and eight point gaps`() {
        let widths: [CGFloat] = [12.5, 13, 15.5, 15, 13, 11.5, 12.5, 13]
        let layout = NativePageControlLayout(
            count: 8,
            selection: 2,
            availableLength: 240,
            symbolWidths: widths)
        #expect(layout.length == 190)
        #expect(layout.start == 25)
        #expect(layout.position(of: 0) == 45.5)
        #expect(layout.position(of: 2) == 88.5)
        for index in 1..<widths.count {
            let gap = layout.position(of: index) - widths[index] / 2
                - layout.position(of: index - 1) - widths[index - 1] / 2
            #expect(abs(gap - 8) <= 0.25)
        }
    }

    @Test func `short controls center all marks without overflow`() {
        let layout = NativePageControlLayout(count: 3, selection: 1, availableLength: 240)
        #expect(layout.marks.count == 3)
        #expect(layout.offset == 0)
        #expect(layout.marks[1].position == 120)
        #expect(layout.marks.allSatisfy { $0.scale == 1 })
    }

    @Test func `native default metrics reproduce the measured Catalyst viewport`() {
        let layout = NativePageControlLayout(
            count: 30,
            selection: 15,
            availableLength: 240,
            pitch: 18,
            glyphSize: 10)
        #expect(layout.length == 200)
        #expect(layout.offset == 144)
        #expect(layout.position(of: 15) == 165)
        #expect(abs(layout.scale(at: 39) - 0.44609) < 0.001)
        #expect(abs(layout.scale(at: 57) - 0.75877) < 0.001)
    }

    @Test func `changing selection preserves the viewport until its full-size boundary is reached`() {
        let first = NativePageControlLayout(count: 40, selection: 15, availableLength: 240)
        let previous = NativePageControlLayout(
            count: 40,
            selection: 14,
            availableLength: 240,
            previousOffset: first.offset)
        #expect(previous.offset == first.offset)
        let next = NativePageControlLayout(
            count: 40,
            selection: 16,
            availableLength: 240,
            previousOffset: first.offset)
        #expect(next.offset == first.offset + first.pitch)
        #expect(next.marks.contains { $0.index == 16 && $0.scale == 1 })
    }

    @Test func `overflow stays bounded with thousands of pages and every selection visible`() {
        for index in [0, 1, 5, 99, 998, 999] {
            let layout = NativePageControlLayout(count: 1000, selection: index, availableLength: 240)
            #expect(layout.marks.count <= 15)
            #expect(layout.offset >= 0 && layout.offset <= layout.maximumOffset)
            #expect(layout.marks.contains { $0.index == index && $0.scale == 1 })
        }
    }

    @Test func `right-to-left and bottom-to-top mirror hit targets and movement`() {
        let forward = NativePageControlLayout(count: 5, selection: 2, availableLength: 240)
        let reverse = NativePageControlLayout(count: 5, selection: 2, availableLength: 240, reversed: true)
        for index in 0..<5 {
            #expect(forward.position(of: index) + reverse.position(of: index) == 240)
            #expect(reverse.hit(at: reverse.position(of: index)) == .indicator(index))
        }
        #expect(NativePageControlDirection.natural.isReversed(rightToLeft: true))
        #expect(NativePageControlDirection.bottomToTop.isReversed(rightToLeft: false))
        #expect(!NativePageControlDirection.topToBottom.isReversed(rightToLeft: true))
    }

    @Test func `padding clicks move one page and direct mark clicks target their page`() {
        let layout = NativePageControlLayout(count: 5, selection: 2, availableLength: 240)
        #expect(layout.hit(at: layout.start + 1) == .step(-1))
        #expect(layout.hit(at: layout.end - 1) == .step(1))
        #expect(layout.hit(at: layout.position(of: 4)) == .indicator(4))
        #expect(layout.hit(at: layout.start - 1) == nil)
    }

    @Test func `zero pages zero space and missing selections are safe`() {
        #expect(NativePageControlLayout(count: 0, selection: 0, availableLength: 240).marks.isEmpty)
        #expect(NativePageControlLayout(count: 20, selection: 19, availableLength: 0).marks.isEmpty)
        let small = NativePageControlLayout(count: 20, selection: 100, availableLength: 24)
        #expect(small.selection == 19)
        #expect(small.marks.contains { $0.index == 19 })
    }

    @Test func `scrubbing traverses real pages independently of changing provider indicator groups`() {
        let pages = (0..<20).map { "account-\($0)" }
        var tracking = NativePageControlTracking(
            pageIDs: pages,
            selectedID: pages[2],
            touchedID: pages[2],
            position: 100,
            lowerEdge: 20,
            upperEdge: 220)
        #expect(tracking.update(position: 122) == pages[3])
        #expect(tracking.interaction == .continuous)
        // Expanding a new provider changes the displayed dots, not this frozen logical page sequence.
        #expect(tracking.update(position: 144) == pages[4])
        #expect(tracking.update(position: 78) == pages[1])
    }

    @Test func `small pointer movement remains a discrete click and a hold begins scrubbing`() {
        var tracking = self.tracking()
        #expect(tracking.update(position: 102) == nil)
        #expect(tracking.interaction == .discrete)
        #expect(tracking.update(position: 102, forceContinuous: true) == "3")
        #expect(tracking.interaction == .continuous)
    }

    @Test func `continuous interaction can be disabled`() {
        var tracking = self.tracking(continuous: false)
        #expect(tracking.update(position: 180) == nil)
        #expect(tracking.update(position: 180, forceContinuous: true) == nil)
        #expect(tracking.interaction == .discrete)
        #expect(tracking.movedBeyondClick)
        #expect(tracking.advanceEdge() == nil)
    }

    @Test func `edge scrubbing advances without movement clamps and reverses without jumping`() {
        var tracking = self.tracking()
        _ = tracking.update(position: 230)
        let first = tracking.index
        #expect(tracking.edgeDirection == 1)
        #expect(tracking.advanceEdge() == String(first + 1))
        #expect(tracking.advanceEdge() == String(first + 2))
        _ = tracking.update(position: 208)
        #expect(tracking.index == first + 1)
        #expect(tracking.edgeDirection == 0)
        _ = tracking.update(position: 10000)
        #expect(tracking.index == 29)
        #expect(tracking.advanceEdge() == nil)
    }

    @Test func `RTL scrubbing reverses physical motion and leading edge acceleration`() {
        var tracking = NativePageControlTracking(
            pageIDs: (0..<30).map(String.init),
            selectedID: "10",
            touchedID: "10",
            position: 100,
            lowerEdge: 20,
            upperEdge: 220,
            reversed: true)
        #expect(tracking.update(position: 78) == "11")
        _ = tracking.update(position: 0)
        #expect(tracking.edgeDirection == 1)
        let current = tracking.index
        #expect(tracking.advanceEdge() == String(current + 1))
    }

    @Test func `wheel deltas preserve small movements and coarse wheels advance one page`() {
        var wheel = NativePageControlWheel()
        #expect(wheel.consume(delta: -5, precise: true) == 0)
        #expect(wheel.consume(delta: -5, precise: true) == 0)
        #expect(wheel.consume(delta: -10, precise: true) == 1)
        #expect(wheel.consume(delta: 1, precise: false) == -1)
        wheel.reset()
        #expect(wheel.consume(delta: 19, precise: true) == 0)
    }

    private func tracking(continuous: Bool = true) -> NativePageControlTracking {
        .init(
            pageIDs: (0..<30).map(String.init),
            selectedID: "3",
            touchedID: "3",
            position: 100,
            lowerEdge: 20,
            upperEdge: 220,
            allowsContinuousInteraction: continuous)
    }

    @Test func `edge timer restarts after reaching a boundary and ignores stale completions`() throws {
        var repeatState = NativePageControlRepeatState()
        let firstValue = repeatState.begin(direction: 1)
        let first = try #require(firstValue)
        let duplicate = repeatState.begin(direction: 1)
        #expect(duplicate == nil)
        let finished = repeatState.finish(first)
        #expect(finished)
        let restartedValue = repeatState.begin(direction: 1)
        let restarted = try #require(restartedValue)
        let staleFirst = repeatState.finish(first)
        #expect(!staleFirst)
        let reversedValue = repeatState.begin(direction: -1)
        let reversed = try #require(reversedValue)
        let staleRestart = repeatState.finish(restarted)
        #expect(!staleRestart)
        #expect(repeatState.direction == -1)
        repeatState.cancel()
        let staleCancelled = repeatState.finish(reversed)
        #expect(!staleCancelled)
        let afterCancel = repeatState.begin(direction: -1)
        #expect(afterCancel != nil)
    }
}
