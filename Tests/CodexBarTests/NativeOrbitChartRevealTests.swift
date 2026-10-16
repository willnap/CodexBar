import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitChartRevealTests {
    @Test("startup reveal retains full-size chart content behind a native clip")
    func retainedChart() {
        let view = NativeOrbitChartRevealView(content: AnyView(Text("Recorded usage")), phase: .armed)
        let host = view.host
        #expect(view.clip.clipsToBounds)
        #expect(view.revealMask.bounds.width == 0)
        #expect(host.frame.size == CGSize(width: 224, height: 224))
        #expect(host.frame.origin == .zero)
        #expect(host.layer?.transform.m42 == 3)

        for phase in [NativeOrbitStartupPhase.sweeping, .settling, .live, .armed, .reduced, .live] {
            let progress = CGFloat(phase.graphReveal)
            view.reveal(phase, animated: false)
            #expect(view.host === host)
            #expect(host.frame.size == CGSize(width: 224, height: 224))
            #expect(view.clip.frame == CGRect(x: 0, y: 0, width: 224, height: 224))
            #expect(host.frame.origin == .zero)
            #expect(view.revealMask.bounds.width == 224 * progress)
            #expect(view.clip.layer?.opacity == Float(phase.graphReveal))
            #expect(host.layer?.transform.m42 == 3 * (1 - progress))
            #expect(view.clip.layer?.mask === view.revealMask)
        }
    }

    @Test("resizing the chart changes its layout independently of the reveal clip")
    func layoutSize() {
        let view = NativeOrbitChartRevealView(content: AnyView(Color.clear), phase: .armed)
        view.setFrameSize(CGSize(width: 300, height: 240))
        view.layout()
        #expect(view.host.frame.size == CGSize(width: 300, height: 240))
        #expect(view.clip.frame.size == CGSize(width: 300, height: 240))
        #expect(view.revealMask.bounds.size == CGSize(width: 0, height: 240))
        view.reveal(.sweeping, animated: false)
        #expect(view.host.frame.size == CGSize(width: 300, height: 240))
        #expect(view.clip.frame.size == CGSize(width: 300, height: 240))
        #expect(view.revealMask.bounds.size == CGSize(width: 300, height: 240))
    }

    @Test("inspection interrupts the compositor sweep and reveals the whole chart immediately")
    func inspectionInterruptsSweep() {
        let view = NativeOrbitChartRevealView(content: AnyView(Color.clear), phase: .armed)
        view.reveal(.sweeping, animated: true)
        #expect(view.revealMask.animation(forKey: "startupReveal") != nil)
        view.reveal(.live, animated: false)
        #expect(view.revealMask.animation(forKey: "startupReveal") == nil)
        #expect(view.clip.layer?.animation(forKey: "startupReveal") == nil)
        #expect(view.host.layer?.animation(forKey: "startupReveal") == nil)
        #expect(view.revealMask.bounds.width == 224)
        #expect(view.clip.layer?.opacity == 1)
        #expect(view.host.layer?.transform.m42 == 0)
    }

    @Test("compositor reveal leaves native geometry fixed and arming cancels every animation")
    func compositorAnimation() throws {
        let view = NativeOrbitChartRevealView(content: AnyView(Color.clear), phase: .armed)
        let clipFrame = view.clip.frame
        let hostFrame = view.host.frame
        view.reveal(.sweeping, animated: true)
        #expect(view.clip.frame == clipFrame)
        #expect(view.host.frame == hostFrame)
        let animation = try #require(view.revealMask.animation(forKey: "startupReveal") as? CABasicAnimation)
        #expect(animation.keyPath == "bounds.size.width")
        #expect(animation.duration == 0.64)
        #expect((animation.preferredFrameRateRange.preferred ?? 0) > 0)
        view.reveal(.settling, animated: true)
        #expect(view.revealMask.animation(forKey: "startupReveal")?.duration == 0.64)
        view.reveal(.armed, animated: true)
        #expect(view.revealMask.animation(forKey: "startupReveal") == nil)
        #expect(view.clip.layer?.animation(forKey: "startupReveal") == nil)
        #expect(view.host.layer?.animation(forKey: "startupReveal") == nil)
        #expect(view.revealMask.bounds.width == 0)
        #expect(view.clip.layer?.opacity == 0)
        #expect(view.host.layer?.transform.m42 == 3)
        #expect(view.clip.frame == clipFrame)
        #expect(view.host.frame == hostFrame)
        view.reveal(.reduced, animated: false)
        view.reveal(.live, animated: true)
        #expect(view.revealMask.animation(forKey: "startupReveal")?.duration == 0.15)
    }
}
