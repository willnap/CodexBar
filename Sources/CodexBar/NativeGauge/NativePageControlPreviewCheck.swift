import AppKit

/// Exercises only the fixture's own view hierarchy. Events are delivered directly to its control, never posted
/// to the desktop; native scroll offsets verify that input reaches the production page strip rather than just its dots.
@MainActor
enum NativePageControlPreviewCheck {
    static func run(view: NSView, model: NativeCombinedAccounts, directory: URL) async {
        var results: [[String: Any]] = []
        await self.settle(view)
        // The page strip is the scroll view whose content is widest; pages inside it do not scroll sideways.
        guard let control = self.descendants(view).compactMap({ $0 as? NativePageControlInputControl }).first,
              let strip = self.descendants(view).compactMap({ $0 as? NSScrollView })
                  .max(by: { ($0.documentView?.frame.width ?? 0) < ($1.documentView?.frame.width ?? 0) })
        else {
            self.write(
                ["passed": false, "error": "Production page control or page strip missing"],
                to: directory)
            return
        }
        func check(_ name: String, index: Int) {
            let visible = strip.contentView.bounds
            let page = CGRect(
                x: CGFloat(index) * NativeCombinedPopupView.pitch,
                y: visible.minY,
                width: NativeCombinedPopupView.pageWidth,
                height: 1)
            let shown = visible.insetBy(dx: -1, dy: 0).contains(page)
            results.append([
                "name": name,
                "selected": control.currentIndex,
                "expected": index,
                "scrollOffset": visible.minX,
                "selectedPageVisible": shown,
                "passed": control.currentIndex == index && shown,
            ])
        }
        func send(_ type: NSEvent.EventType, x: CGFloat) {
            let point = control.convert(CGPoint(x: x, y: 18), to: nil)
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: control.window?.windowNumber ?? 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1) else { return }
            switch type {
            case .leftMouseDown: control.mouseDown(with: event)
            case .leftMouseDragged: control.mouseDragged(with: event)
            case .leftMouseUp: control.mouseUp(with: event)
            default: break
            }
        }
        func location(targetID: String) -> CGFloat? {
            let selected = control.pages[control.currentIndex].id
            let indicators = model.indicators(selectedID: selected)
            guard let target = indicators.firstIndex(where: { $0.targetID == targetID && $0.accountID == nil })
                ?? indicators.firstIndex(where: { $0.targetID == targetID }) else { return nil }
            return NativePageControlLayout(
                count: indicators.count,
                selection: indicators.firstIndex(where: \.selected) ?? 0,
                availableLength: control.bounds.width,
                pitch: 22,
                symbolWidths: indicators.map {
                    NativePageControlSymbol($0, configuration: .init()).size.width
                }).position(of: target)
        }
        func click(_ index: Int) async {
            guard let x = location(targetID: control.pages[index].id) else { return }
            send(.leftMouseDown, x: x)
            send(.leftMouseUp, x: x)
            await self.settle(view)
        }
        func key(_ code: UInt16) async {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: control.window?.windowNumber ?? 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: code) else { return }
            control.keyDown(with: event)
            await self.settle(view)
        }
        check("initial account opens after overview", index: 1)
        await click(7)
        check("provider logo selects its real page", index: 7)
        await click(4)
        check("another provider expands account symbols", index: 4)
        await click(6)
        check("account symbol selects its real page", index: 6)
        _ = control.accessibilityPerformDecrement()
        _ = control.accessibilityPerformDecrement()
        await self.settle(view)
        check("repeated accessibility changes stay synchronized", index: 4)
        await key(115)
        check("Home reaches overview", index: 0)
        await key(124)
        check("arrow reaches first account", index: 1)
        if let x = location(targetID: control.pages[1].id) {
            send(.leftMouseDown, x: x)
            send(.leftMouseDragged, x: x + 88)
            await self.settle(view)
            check("scrub crosses provider boundary without retargeting", index: 5)
            send(.leftMouseUp, x: x + 88)
        }
        await key(115)
        if let x = location(targetID: control.pages[0].id) {
            send(.leftMouseDown, x: x)
            send(.leftMouseDragged, x: x + 220)
            await self.settle(view)
            check("edge scrub clamps to last account", index: 8)
            send(.leftMouseDragged, x: x + 154)
            await self.settle(view)
            check("edge repeat restarts after boundary and inward drag", index: 8)
            send(.leftMouseUp, x: 400)
        }
        await key(115)
        check("release outside ends scrubbing", index: 0)
        await click(4)
        await results.append(self.checkReversal(view: view, control: control, accountID: model.pages[3].id))
        await self.settle(view)
        check("rapid provider reversal settles on its real account", index: 4)
        let renderer = self.descendants(view).compactMap { $0 as? NativePageControlLayerView }.first
        let framePassed = abs(control.bounds.width - 240) < 1 && abs(control.bounds.height - 36) < 1
            && renderer?.bounds.size == control.bounds.size
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let positions = NativePageControlMotionTrace.positions[NativeCombinedAccounts.overviewID]?.count ?? 0
        let motionPassed = reducedMotion || (NativePageControlMotionTrace.intermediateTintSamples > 0 && positions > 4)
        self.write([
            "passed": framePassed && motionPassed && results.allSatisfy { $0["passed"] as? Bool == true },
            "controlBounds": NSStringFromRect(control.bounds),
            "rendererBounds": renderer.map { NSStringFromRect($0.bounds) } ?? "missing",
            "framePassed": framePassed,
            "pageCount": control.pages.count,
            "checks": results,
            "motion": [
                "passed": motionPassed,
                "reduceMotion": reducedMotion,
                "intermediateTintSamples": NativePageControlMotionTrace.intermediateTintSamples,
                "overviewDistinctPositions": positions,
                "invalidForegroundSamples": NativePageControlMotionTrace.invalidForegroundSamples,
                "displayIntervalsMS": NativePageControlMotionTrace.displayIntervals,
                "displayBudgetsMS": NativePageControlMotionTrace.displayBudgets,
            ],
        ], to: directory)
        await key(115)
        await key(124)
    }

    private static func checkReversal(
        view: NSView,
        control: NativePageControlInputControl,
        accountID: String) async -> [String: Any]
    {
        guard let renderer = self.descendants(view).compactMap({ $0 as? NativePageControlLayerView }).first else {
            return ["name": "layer renderer exists", "passed": false]
        }
        func glyphs() -> [CALayer] {
            renderer.layer.map { self.layers($0).filter { $0.name == accountID } } ?? []
        }
        let original = glyphs().first
        control.onSelect(7)
        try? await Task.sleep(for: .milliseconds(60))
        control.onSelect(4)
        try? await Task.sleep(for: .milliseconds(60))
        let revived = glyphs()
        return [
            "name": "rapid provider reversal revives the same glyph without duplicates",
            "passed": original != nil && revived.count == 1 && revived.first === original,
            "matchingLayers": revived.count,
        ]
    }

    private static func settle(_ view: NSView) async {
        try? await Task.sleep(for: .milliseconds(550))
        view.layoutSubtreeIfNeeded()
    }

    private static func layers(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap(self.layers)
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(self.descendants)
    }

    private static func write(_ report: [String: Any], to directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("page-control-check.json"))
        } catch {
            print("Native page control fixture check failed: \(error.localizedDescription)")
        }
    }
}
