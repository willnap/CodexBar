import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct NativeAccountPagerTests {
    @Test func `native page controllers retain the selected account identity through reuse`() {
        let parent = self.pager()
        let coordinator = NativeAccountPager.Coordinator(parent)
        let controller = self.controller(coordinator)
        for index in [0, 2, 1, 0, 2] {
            controller.selectedIndex = index
            controller.completeTransition()
            #expect(controller.visiblePageID == parent.ids[index])
        }
        #expect(controller.transitionStyle == .horizontalStrip)
    }

    @Test func `reordering native pages preserves the requested stable account identity`() {
        let coordinator = NativeAccountPager.Coordinator(self.pager())
        let controller = self.controller(coordinator)
        controller.selectedIndex = 2
        controller.completeTransition()
        controller.arrangedObjects = ["claude:one", "overview", "codex:one"]
        controller.selectedIndex = 0
        controller.completeTransition()
        #expect(controller.visiblePageID == "claude:one")
        #expect(coordinator.pageController(controller, identifierFor: "codex:one") == "codex:one")
        #expect(coordinator.pageController(controller, identifierFor: "claude:one") == "claude:one")
    }

    @Test func `shrinking native inventory from its last page selects the remaining overview`() {
        let coordinator = NativeAccountPager.Coordinator(self.pager())
        let controller = self.controller(coordinator)
        controller.selectedIndex = 2
        controller.completeTransition()
        controller.arrangedObjects = ["overview"]
        controller.selectedIndex = 0
        controller.completeTransition()
        #expect(controller.visiblePageID == "overview")
    }

    @Test func `unchanged cached pages retain their existing SwiftUI content`() throws {
        var configurations = 0
        let parent = NativeAccountPager(
            ids: ["overview"],
            selectedID: "overview",
            request: nil,
            revision: [],
            reduceMotion: true,
            content: { id in configurations += 1; return AnyView(Text(id)) },
            interactionBegan: { _ in },
            visible: { _ in })
        let coordinator = NativeAccountPager.Coordinator(parent)
        let controller = self.controller(coordinator)
        let host = try #require(controller.selectedViewController)
        let before = configurations
        coordinator.pageController(controller, prepare: host, with: "overview")
        coordinator.pageController(controller, prepare: host, with: "overview")
        #expect(configurations == before)
        coordinator.parent = NativeAccountPager(
            ids: parent.ids,
            selectedID: parent.selectedID,
            request: nil,
            revision: [Date(timeIntervalSince1970: 1)],
            reduceMotion: true,
            content: parent.content,
            interactionBegan: parent.interactionBegan,
            visible: parent.visible)
        coordinator.pageController(controller, prepare: host, with: "overview")
        #expect(configurations == before + 1)
        coordinator.parent.layoutDirection = .rightToLeft
        coordinator.pageController(controller, prepare: host, with: "overview")
        #expect(configurations == before + 2)
    }

    private func pager() -> NativeAccountPager {
        NativeAccountPager(
            ids: ["overview", "codex:one", "claude:one"],
            selectedID: "overview",
            request: nil,
            revision: [],
            reduceMotion: true,
            content: { AnyView(Text($0)) },
            interactionBegan: { _ in },
            visible: { _ in })
    }

    private func controller(_ coordinator: NativeAccountPager.Coordinator) -> NativeAccountPageController {
        let controller = NativeAccountPageController()
        controller.delegate = coordinator
        controller.transitionStyle = .horizontalStrip
        controller.view = NativeAccountPagerSurface(frame: CGRect(x: 0, y: 0, width: 240, height: 500))
        controller.arrangedObjects = coordinator.parent.ids
        controller.completeTransition()
        return controller
    }
}
