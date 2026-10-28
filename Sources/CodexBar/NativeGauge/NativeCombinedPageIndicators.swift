import AppKit
import SwiftUI

/// A SwiftUI port of the system page control's viewport and discrete/continuous interaction model. AppKit
/// supplies the input/accessibility element; the account pager remains the owner of the selected page.
struct NativeCombinedPageIndicators: View {
    let indicators: [NativeCombinedAccounts.Indicator]
    let pages: [NativePageControlPage]
    let selectionID: String
    let select: (String, NativePageControlInteraction) -> Void
    var configuration = NativePageControlConfiguration()
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewportOffset: CGFloat = 0
    @State private var tracking: NativePageControlTracking?
    @State private var latestPosition: CGFloat = 0
    @State private var hovered = false
    @State private var holdTask: Task<Void, Never>?
    @State private var edgeTask: Task<Void, Never>?
    @State private var repeatState = NativePageControlRepeatState()

    private var continuous: Bool {
        self.tracking?.interaction == .continuous
    }

    private var reversed: Bool {
        self.configuration.direction.isReversed(rightToLeft: self.layoutDirection == .rightToLeft)
    }

    private var pageIDs: [String] {
        self.pages.map(\.id)
    }

    private var index: Int {
        self.pages.firstIndex { $0.id == self.selectionID } ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            let length = self.configuration.direction.isVertical ? geometry.size.height : geometry.size.width
            let layout = NativePageControlLayout(
                count: self.indicators.count,
                selection: self.indicators.firstIndex(where: \.selected) ?? 0,
                availableLength: length,
                previousOffset: self.viewportOffset,
                reversed: self.reversed,
                pitch: 22,
                glyphSize: 12,
                symbolWidths: self.indicators.map {
                    NativePageControlImageMetrics.length(
                        NativePageControlSymbol($0, configuration: self.configuration).size,
                        vertical: self.configuration.direction.isVertical)
                },
                groups: self.indicators.map { $0.expanded ? $0.group : nil })
            let artwork = NativePageControlArtwork(
                indicators: self.indicators,
                layout: layout,
                configuration: self.configuration,
                expanded: self.continuous,
                hovered: self.hovered,
                enabled: self.isEnabled)
            if !self.pages.isEmpty, !(self.configuration.hidesForSinglePage && self.pages.count == 1) {
                LayerArtwork(artwork: artwork, reduceMotion: self.reduceMotion)
                    .overlay {
                        InputBridge(
                            controlFrame: artwork.controlFrame,
                            pages: self.pages,
                            index: self.index,
                            vertical: self.configuration.direction.isVertical,
                            reversed: self.reversed,
                            enabled: self.isEnabled,
                            pointer: { self.pointer($0, layout: layout) },
                            select: { index, interaction in
                                self.stopInteraction()
                                if self.pages.indices.contains(index) { self.select(self.pages[index].id, interaction) }
                            },
                            hover: { self.hovered = $0 },
                            cancel: self.stopInteraction)
                    }
                    .onChange(of: layout.offset, initial: true) { self.viewportOffset = layout.offset }
            }
        }
        .frame(
            width: self.configuration.direction.isVertical ? 36 : nil,
            height: self.configuration.direction.isVertical ? nil : NativeCombinedPopupView.indicatorHeight)
        .onChange(of: self.pageIDs) { self.stopInteraction() }
        .onChange(of: self.configuration.direction) { self.stopInteraction(); self.viewportOffset = 0 }
        .onChange(of: self.isEnabled) { if !self.isEnabled { self.stopInteraction() } }
        .onDisappear { self.stopInteraction() }
    }

    private func coordinate(_ point: CGPoint) -> CGFloat {
        self.configuration.direction.isVertical ? point.y : point.x
    }

    private func target(at position: CGFloat, layout: NativePageControlLayout) -> String? {
        switch layout.hit(at: position) {
        case let .indicator(index):
            self.indicators.indices.contains(index) ? self.indicators[index].targetID : nil
        case let .step(delta):
            self.pages.isEmpty ? nil : self.pages[min(self.pages.count - 1, max(0, self.index + delta))].id
        case nil: nil
        }
    }

    private func pointer(_ event: NativePageControlPointer, layout: NativePageControlLayout) {
        let position = self.coordinate(event.position)
        self.latestPosition = position
        switch event.phase {
        case .down:
            self.stopInteraction()
            guard let target = self.target(at: position, layout: layout), self.isEnabled else { return }
            self.tracking = NativePageControlTracking(
                pageIDs: self.pageIDs,
                selectedID: self.selectionID,
                touchedID: target,
                position: position,
                lowerEdge: layout.start,
                upperEdge: layout.end,
                reversed: self.reversed,
                allowsContinuousInteraction: self.configuration.allowsContinuousInteraction)
            if self.configuration.allowsContinuousInteraction {
                self.holdTask = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    self.scrub(position: self.latestPosition, forceContinuous: true)
                }
            }
        case .dragged:
            self.scrub(position: position)
        case .up:
            guard let tracking = self.tracking else { return }
            if tracking.interaction == .continuous {
                self.scrub(position: position)
            } else if !tracking.movedBeyondClick, let target = self.target(at: position, layout: layout) {
                self.select(target, .discrete)
            }
            self.stopInteraction()
        }
    }

    private func scrub(position: CGFloat, forceContinuous: Bool = false) {
        guard var tracking = self.tracking, self.isEnabled else { return }
        let target = tracking.update(position: position, forceContinuous: forceContinuous)
        self.tracking = tracking
        if let target { self.select(target, .continuous) }
        self.synchronizeEdgeTask(direction: tracking.edgeDirection)
    }

    private func synchronizeEdgeTask(direction: Int) {
        if direction == 0 {
            self.repeatState.cancel()
            self.edgeTask?.cancel()
            self.edgeTask = nil
            return
        }
        guard let generation = self.repeatState.begin(direction: direction) else { return }
        self.edgeTask?.cancel()
        self.edgeTask = Task { @MainActor in
            defer {
                if self.repeatState.finish(generation) { self.edgeTask = nil }
            }
            var ticks = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(ticks == 0 ? 350 : ticks < 8 ? 150 : 80))
                } catch { return }
                guard var tracking = self.tracking, tracking.edgeDirection == direction, self.isEnabled,
                      let target = tracking.advanceEdge()
                else { return }
                self.tracking = tracking
                self.select(target, .continuous)
                ticks += 1
            }
        }
    }

    private func stopInteraction() {
        self.repeatState.cancel()
        self.holdTask?.cancel()
        self.edgeTask?.cancel()
        self.holdTask = nil
        self.edgeTask = nil
        self.tracking = nil
    }

    private struct LayerArtwork: NSViewRepresentable {
        let artwork: NativePageControlArtwork
        let reduceMotion: Bool

        func makeNSView(context _: Context) -> NativePageControlLayerView {
            NativePageControlLayerView(frame: .zero)
        }

        func updateNSView(_ view: NativePageControlLayerView, context _: Context) {
            view.update(self.artwork, reduceMotion: self.reduceMotion)
        }
    }

    private struct InputBridge: NSViewRepresentable {
        let controlFrame: CGRect
        let pages: [NativePageControlPage]
        let index: Int
        let vertical: Bool
        let reversed: Bool
        let enabled: Bool
        let pointer: (NativePageControlPointer) -> Void
        let select: (Int, NativePageControlInteraction) -> Void
        let hover: (Bool) -> Void
        let cancel: () -> Void

        func makeNSView(context _: Context) -> NativePageControlInputControl {
            NativePageControlInputControl(frame: .zero)
        }

        func updateNSView(_ view: NativePageControlInputControl, context _: Context) {
            if view.controlFrame != self.controlFrame { view.controlFrame = self.controlFrame }
            if view.pages != self.pages { view.pages = self.pages }
            if view.currentIndex != self.index { view.currentIndex = self.index }
            view.vertical = self.vertical
            view.reversed = self.reversed
            view.isEnabled = self.enabled
            view.onPointer = self.pointer
            view.onSelect = { [weak view] index in self.select(index, view?.interaction ?? .discrete) }
            view.onHover = self.hover
            view.onCancel = self.cancel
            view.setAccessibilityLabel(L("Account pages"))
            view.setAccessibilityIdentifier("CodexBar.AccountPageControl")
        }
    }
}
