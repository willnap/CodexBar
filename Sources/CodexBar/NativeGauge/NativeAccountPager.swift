import AppKit
import SwiftUI

/// AppKit owns horizontal swipe physics, reusable page controllers, and snapshot transitions.
struct NativeAccountPager: NSViewControllerRepresentable {
    let ids: [String]
    let selectedID: String
    let request: NativePageControlNavigation.Request?
    let revision: [Date]
    let reduceMotion: Bool
    var layoutDirection: LayoutDirection = .leftToRight
    let content: (String) -> AnyView
    let interactionBegan: (String) -> Void
    let visible: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSViewController(context: Context) -> NativeAccountPageController {
        let controller = NativeAccountPageController()
        controller.delegate = context.coordinator
        controller.transitionStyle = .horizontalStrip
        let surface = NativeAccountPagerSurface(frame: CGRect(
            x: 0,
            y: 0,
            width: 240,
            height: NativeCombinedPopupView.pageHeight))
        surface.controller = controller
        controller.view = surface
        controller.view.userInterfaceLayoutDirection = .leftToRight
        controller.arrangedObjects = self.ids
        controller.selectedIndex = self.ids.firstIndex(of: self.selectedID) ?? 0
        controller.completeTransition()
        return controller
    }

    func updateNSViewController(_ controller: NativeAccountPageController, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.parent.revision != self.revision
            || coordinator.parent.layoutDirection != self.layoutDirection
        coordinator.parent = self
        if controller.arrangedObjects as? [String] != self.ids {
            controller.arrangedObjects = self.ids
            controller.selectedIndex = self.ids.firstIndex(of: self.selectedID) ?? 0
            controller.completeTransition()
        }
        if changed, let host = controller.selectedViewController as? NativeAccountPageHost,
           let id = host.pageID
        {
            host.revision = self.revision
            host.layoutDirection = self.layoutDirection
            host.rootView = self.content(id)
        }
        guard let request = self.request, request.generation != coordinator.lastRequest,
              let index = self.ids.firstIndex(of: request.id) else { return }
        coordinator.lastRequest = request.generation
        if controller.selectedIndex == index, controller.visiblePageID == request.id {
            coordinator.reportVisible(controller)
            return
        }
        if self.reduceMotion || request.interaction == .continuous || controller.view.window == nil {
            controller.selectedIndex = index
            controller.completeTransition()
            coordinator.reportVisible(controller)
        } else {
            coordinator.invokingAction = true
            controller.takeSelectedIndexFrom(NSNumber(value: index))
            coordinator.invokingAction = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSPageControllerDelegate {
        var parent: NativeAccountPager
        var lastRequest: UUID?
        var invokingAction = false

        init(_ parent: NativeAccountPager) { self.parent = parent }

        func pageController(_: NSPageController, identifierFor object: Any) -> NSPageController.ObjectIdentifier {
            object as? String ?? "overview"
        }

        func pageController(
            _: NSPageController,
            viewControllerForIdentifier _: NSPageController.ObjectIdentifier) -> NSViewController
        {
            NativeAccountPageHost(rootView: AnyView(Color.clear))
        }

        func pageController(_ controller: NSPageController, frameFor _: Any?) -> NSRect {
            controller.view.bounds
        }

        func pageController(_: NSPageController, prepare viewController: NSViewController, with object: Any?) {
            guard let host = viewController as? NativeAccountPageHost, let id = object as? String else { return }
            guard host.pageID != id || host.revision != self.parent.revision
                || host.layoutDirection != self.parent.layoutDirection else { return }
            host.pageID = id
            host.revision = self.parent.revision
            host.layoutDirection = self.parent.layoutDirection
            host.rootView = self.parent.content(id)
        }

        func pageControllerWillStartLiveTransition(_ controller: NSPageController) {
            if !self.invokingAction, self.parent.ids.indices.contains(controller.selectedIndex) {
                self.parent.interactionBegan(self.parent.ids[controller.selectedIndex])
            }
        }

        func pageControllerDidEndLiveTransition(_ controller: NSPageController) {
            controller.completeTransition()
            self.reportVisible(controller)
        }

        func reportVisible(_ controller: NSPageController) {
            guard self.parent.ids.indices.contains(controller.selectedIndex) else { return }
            let id = self.parent.ids[controller.selectedIndex]
            Task { @MainActor [weak self, weak controller] in
                guard let self, let controller,
                      self.parent.ids.indices.contains(controller.selectedIndex),
                      self.parent.ids[controller.selectedIndex] == id else { return }
                self.parent.visible(id)
            }
        }
    }
}

@MainActor
final class NativeAccountPageController: NSPageController {
    var visiblePageID: String? {
        (self.selectedViewController as? NativeAccountPageHost)?.pageID
    }
}

@MainActor
final class NativeAccountPagerSurface: NSView {
    weak var controller: NativeAccountPageController?
    override var isFlipped: Bool {
        true
    }
}

@MainActor
private final class NativeAccountPageHost: NSHostingController<AnyView> {
    var pageID: String?
    var revision: [Date] = []
    var layoutDirection: LayoutDirection = .leftToRight
}
