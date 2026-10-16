import AppKit
import Metal
import QuartzCore
import SwiftUI

enum NativeOrbitWarningHDRColor: Equatable {
    case caution
    case critical
    case opportunity

    /// Headroom beyond the lamp's emission cap produces identical pixels, including Float conversion precision.
    static func renderingHeadroom(_ headroom: CGFloat, darkAppearance: Bool) -> CGFloat {
        let available = headroom.isFinite ? max(1, Float(headroom)) : 1
        return CGFloat(min(available, darkAppearance ? 2.0 : 1.5))
    }

    /// Linear-light catalogue colours with a saturated luminous core when EDR headroom is available.
    func emission(headroom: CGFloat, darkAppearance: Bool) -> SIMD3<Float> {
        let available = headroom.isFinite ? max(1, Float(headroom)) : 1
        let gain = min(available, darkAppearance ? 2.0 : 1.5)
        // Catalogue colours converted from sRGB into linear light. Increasing all three channels made
        // amber turn lemon-yellow and green turn minty; the lamp's dominant channel carries the EDR gain.
        var color: SIMD3<Float> = switch self {
        case .caution: SIMD3(0.80695, 0.341914, 0)
        case .critical: SIMD3(1, 0.043735, 0.029557)
        case .opportunity: SIMD3(0.033105, 0.571125, 0.099899)
        }
        if available > 1 {
            if self == .opportunity { color.y = gain } else { color.x = gain }
        }
        return color
    }
}

struct NativeOrbitWarningHDRItem: Equatable, Identifiable {
    let id: String
    let symbol: String
    /// Offset from the dial centre, with positive y pointing down, as in SwiftUI.
    let position: CGPoint
    let color: NativeOrbitWarningHDRColor
}

extension NativeOrbitWarningHDRItem {
    init(light: NativeOrbitWarningLight, position: CGPoint) {
        self.id = light.kind.catalogueKey
        self.symbol = light.kind.symbol
        self.position = position
        self.color = switch light.severity {
        case .opportunity: .opportunity
        case .caution: .caution
        case .critical: .critical
        }
    }
}

/// A native floating-point surface: the glyph pixels themselves exceed SDR white when the screen has headroom.
/// The containing SwiftUI view owns accessibility and clear button targets; this surface only supplies light.
struct NativeOrbitWarningHDRView: NSViewRepresentable {
    let items: [NativeOrbitWarningHDRItem]

    static func symbolSize(_ symbol: String) -> CGSize {
        NativeOrbitWarningHDRRaster.symbolImage(symbol)?.size ?? .zero
    }

    /// Prepare the exact first catalogue frame before the popup owns a window or drawable.
    static func prepare(
        lanes: Int,
        reservedBounds: CGRect? = nil,
        reservedRegions: [CGRect] = [],
        screen: NSScreen? = nil,
        realLights: [NativeOrbitWarningLight] = [],
        readiness: NativeOrbitStartupReadiness = .pending,
        appearance: NSAppearance? = nil)
    {
        let display = screen ?? NSScreen.main
        let positions = NativeOrbitWarningLayout.positions(
            for: NativeOrbitWarningLight.Kind.allCases,
            lanes: lanes,
            reservedBounds: reservedBounds,
            reservedRegions: reservedRegions)
        let states = self.startupItems(realLights: realLights, readiness: readiness, positions: positions)
        let appearances = appearance.map { [$0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua] }
            ?? [false, true]
        _ = NativeOrbitWarningMetalResources.commandQueue
        // Source light is stable; Core Animation tone maps it as the display's available EDR changes.
        let potential = display?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        for dark in appearances {
            let headroom = NativeOrbitWarningHDRColor.renderingHeadroom(potential, darkAppearance: dark)
            for items in states {
                _ = NativeOrbitWarningHDRRaster.pixels(
                    items: items,
                    size: CGSize(width: 216, height: 216),
                    scale: display?.backingScaleFactor ?? 2,
                    headroom: headroom,
                    darkAppearance: dark,
                    preparing: true)
            }
        }
    }

    /// Tag the fixed linear source so the compositor adapts it to current display headroom without a redraw.
    static func configureDynamicRange(of layer: CALayer, sourceHeadroom: CGFloat) {
        layer.contentsHeadroom = sourceHeadroom
        layer.preferredDynamicRange = sourceHeadroom > 1 ? .high : .standard
        layer.toneMapMode = .ifSupported
    }

    /// Build precisely the same ordered/severity-resolved glyph sets as the live startup view.
    static func startupItems(
        realLights: [NativeOrbitWarningLight],
        readiness: NativeOrbitStartupReadiness,
        positions: [NativeOrbitWarningLight.Kind: CGPoint]) -> [[NativeOrbitWarningHDRItem]]
    {
        let real = NativeOrbitWarningLight.reconciled(realLights)
        let phases: [(NativeOrbitStartupPhase, Int)] = [(.armed, 0)]
            + (0...4).map { (.sweeping, $0) } + [(.settling, 4), (.live, 4)]
        var states: [[NativeOrbitWarningHDRItem]] = []
        for (phase, checkpoint) in phases {
            let items = NativeOrbitStartupChecks.shown(
                realLights: real, phase: phase, checkpoint: checkpoint, readiness: readiness).compactMap { light in
                positions[light.kind].map { NativeOrbitWarningHDRItem(light: light, position: $0) }
            }
            if !states.contains(items) { states.append(items) }
        }
        return states
    }

    func makeNSView(context: Context) -> NativeOrbitWarningHDRSurface {
        NativeOrbitWarningHDRSurface()
    }

    func updateNSView(_ nsView: NativeOrbitWarningHDRSurface, context: Context) {
        if nsView.items != self.items {
            nsView.items = self.items
        }
    }
}

@MainActor
enum NativeOrbitWarningHDRRaster {
    struct Frame: Equatable {
        let items: [NativeOrbitWarningHDRItem]
        let size: CGSize
        let scale: CGFloat
        let headroom: CGFloat
        let darkAppearance: Bool
    }

    private struct GlyphKey: Hashable {
        let symbol: String
        let scale: CGFloat
    }

    private struct Glyph {
        let width: Int
        let height: Int
        let coverage: [UInt8]
    }

    private static var images: [String: NSImage] = [:]
    private static var glyphs: [GlyphKey: Glyph] = [:]
    private static var preparedFrames: [(frame: Frame, pixels: [Float16])] = []
    private static var preparedBytes = 0
    private static let preparedFrameLimit = 96
    private static let preparedByteLimit = 128 * 1024 * 1024
    private static let measuresPerformance = CommandLine.arguments.contains("--preview-performance")
    private static var displayHits = 0
    private static var displayMisses = 0
    private static var preparationMisses = 0
    private static var displayRasterMilliseconds = 0.0
    private static var displayHeadrooms: Set<CGFloat> = []
    private static var displayItemCounts: Set<Int> = []
    private static var presentations = 0
    private static var presentationMilliseconds = 0.0
    private static var maximumPresentationMilliseconds = 0.0
    private static var drawableWaitMilliseconds = 0.0
    private static var maximumDrawableWaitMilliseconds = 0.0

    static var presentationTimestamp: Double? {
        self.measuresPerformance ? CACurrentMediaTime() : nil
    }

    static func recordPresentation(started: Double?, drawableWait: Double) {
        guard let started else { return }
        let elapsed = (CACurrentMediaTime() - started) * 1000
        self.presentations += 1
        self.presentationMilliseconds += elapsed
        self.maximumPresentationMilliseconds = max(self.maximumPresentationMilliseconds, elapsed)
        self.drawableWaitMilliseconds += drawableWait
        self.maximumDrawableWaitMilliseconds = max(self.maximumDrawableWaitMilliseconds, drawableWait)
    }

    static var performanceStatistics: [String: Any] {
        [
            "displayCacheHits": self.displayHits,
            "displayCacheMisses": self.displayMisses,
            "preparationMisses": self.preparationMisses,
            "displayRasterMilliseconds": self.displayRasterMilliseconds,
            "displayHeadrooms": self.displayHeadrooms.sorted(),
            "displayItemCounts": self.displayItemCounts.sorted(),
            "preparedFrames": self.preparedFrames.count,
            "preparedBytes": self.preparedBytes,
            "surfacePresentations": self.presentations,
            "surfaceTotalMilliseconds": self.presentationMilliseconds,
            "surfaceMaxMilliseconds": self.maximumPresentationMilliseconds,
            "drawableWaitMilliseconds": self.drawableWaitMilliseconds,
            "drawableWaitMaxMilliseconds": self.maximumDrawableWaitMilliseconds,
        ]
    }

    static func symbolImage(_ symbol: String) -> NSImage? {
        if let image = images[symbol] { return image }
        // Prefer the original solid dashboard artwork when SF Symbols provides it. Symbols without a filled
        // variant retain their semantic glyph, including on systems where a requested filled name is unavailable.
        let filled = symbol.hasSuffix(".fill") ? symbol : symbol + ".fill"
        let base = symbol.hasSuffix(".fill") ? String(symbol.dropLast(5)) : symbol
        let source = NSImage(systemSymbolName: filled, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: base, accessibilityDescription: nil)
        let image = source?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))?
            .withSymbolConfiguration(.init(paletteColors: [.white]))
        Self.images[symbol] = image
        return image
    }

    /// Kept separate from the drawable so extended-range source pixels can be checked without a window or GPU.
    static func pixels(
        items: [NativeOrbitWarningHDRItem],
        size: CGSize,
        scale: CGFloat,
        headroom: CGFloat,
        darkAppearance: Bool,
        preparing: Bool = false) -> [Float16]
    {
        let headroom = NativeOrbitWarningHDRColor.renderingHeadroom(headroom, darkAppearance: darkAppearance)
        let frame = Frame(
            items: items, size: size, scale: scale, headroom: headroom, darkAppearance: darkAppearance)
        if self.measuresPerformance, !preparing {
            self.displayHeadrooms.insert(headroom)
            self.displayItemCounts.insert(items.count)
        }
        if let index = Self.preparedFrames.firstIndex(where: { $0.frame == frame }) {
            if self.measuresPerformance, !preparing { self.displayHits += 1 }
            let prepared = Self.preparedFrames.remove(at: index)
            Self.preparedFrames.append(prepared)
            return prepared.pixels
        }
        let started = self.measuresPerformance && !preparing ? CACurrentMediaTime() : nil
        if self.measuresPerformance {
            if preparing { self.preparationMisses += 1 } else { self.displayMisses += 1 }
        }
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        var result = [Float16](repeating: 0, count: width * height * 4)
        for item in items {
            guard let image = Self.symbolImage(item.symbol),
                  let glyph = Self.glyph(item.symbol, image: image, scale: scale)
            else { continue }
            let originX = Int(round((size.width / 2 + item.position.x - image.size.width / 2) * scale)) - 2
            let originY = Int(round((size.height / 2 + item.position.y - image.size.height / 2) * scale)) - 2
            let color = item.color.emission(headroom: headroom, darkAppearance: darkAppearance)
            for y in 0..<glyph.height where (0..<height).contains(originY + y) {
                for x in 0..<glyph.width where (0..<width).contains(originX + x) {
                    let glyphIndex = y * glyph.width + x
                    let alpha = Float(glyph.coverage[glyphIndex * 4 + 3]) / 255
                    guard alpha > 0 else { continue }
                    let index = ((originY + y) * width + originX + x) * 4
                    // Premultiplied source-over preserves transparent edges without an SDR matte or halo.
                    let remaining = 1 - alpha
                    result[index] = Float16(color.x * alpha + Float(result[index]) * remaining)
                    result[index + 1] = Float16(color.y * alpha + Float(result[index + 1]) * remaining)
                    result[index + 2] = Float16(color.z * alpha + Float(result[index + 2]) * remaining)
                    result[index + 3] = Float16(alpha + Float(result[index + 3]) * remaining)
                }
            }
        }
        // Retain exact checkpoints across account columns and both appearances; evict by recency and bytes.
        let bytes = result.count * MemoryLayout<Float16>.stride
        while !Self.preparedFrames.isEmpty,
              Self.preparedFrames.count >= self.preparedFrameLimit || Self.preparedBytes + bytes > self
                  .preparedByteLimit
        {
            Self.preparedBytes -= Self.preparedFrames.removeFirst().pixels.count * MemoryLayout<Float16>.stride
        }
        if bytes <= self.preparedByteLimit {
            Self.preparedFrames.append((frame, result))
            Self.preparedBytes += bytes
        }
        if let started { self.displayRasterMilliseconds += (CACurrentMediaTime() - started) * 1000 }
        return result
    }

    private static func glyph(_ symbol: String, image: NSImage, scale: CGFloat) -> Glyph? {
        let key = GlyphKey(symbol: symbol, scale: scale)
        if let glyph = Self.glyphs[key] { return glyph }
        let width = Int(ceil(image.size.width * scale)) + 4
        let height = Int(ceil(image.size.height * scale)) + 4
        // Only coverage is SDR. RGB is emitted by pixels() above, never converted through an 8-bit image.
        var coverage = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = coverage.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            image.draw(
                in: CGRect(origin: CGPoint(x: 2 / scale, y: 2 / scale), size: image.size),
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        guard drawn else { return nil }
        let glyph = Glyph(
            width: width,
            height: height,
            coverage: coverage)
        Self.glyphs[key] = glyph
        return glyph
    }
}

@MainActor
private enum NativeOrbitWarningMetalResources {
    static let device = MTLCreateSystemDefaultDevice()
    static let commandQueue = Self.device?.makeCommandQueue()
}

@MainActor
final class NativeOrbitWarningHDRSurface: NSView {
    var items: [NativeOrbitWarningHDRItem] = [] {
        didSet {
            if self.items != oldValue { self.requestRender() }
        }
    }

    private let device = NativeOrbitWarningMetalResources.device
    private let commandQueue = NativeOrbitWarningMetalResources.commandQueue
    private var renderScheduled = false
    private var lastFrame: NativeOrbitWarningHDRRaster.Frame?

    override var isFlipped: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 216, height: 216))
        self.wantsLayer = true
        self.setAccessibilityElement(false)
        for name in [
            NSApplication.didChangeScreenParametersNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(self.displayEnvironmentChanged), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func makeBackingLayer() -> CALayer {
        guard let device = self.device, self.commandQueue != nil else { return CALayer() }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        NativeOrbitWarningHDRView.configureDynamicRange(of: layer, sourceHeadroom: 1)
        layer.framebufferOnly = false
        layer.isOpaque = false
        layer.backgroundColor = NSColor.clear.cgColor
        layer.allowsNextDrawableTimeout = true
        return layer
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.lastFrame = nil
        self.requestRender()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.requestRender()
    }

    override func layout() {
        super.layout()
        self.requestRender()
    }

    @objc private func displayEnvironmentChanged() {
        self.requestRender()
    }

    override func updateLayer() {
        self.requestRender()
    }

    /// CAMetalLayer manages its own display and does not call NSView.updateLayer in SwiftUI hosting.
    /// Coalesce item, layout and display changes into one frame after AppKit has settled the layer geometry.
    private func requestRender() {
        guard !self.renderScheduled else { return }
        self.renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            guard self.window != nil else { return }
            self.renderFrame()
        }
    }

    private func renderFrame() {
        guard self.bounds.width > 0, self.bounds.height > 0 else { return }
        let scale = self.window?.backingScaleFactor ?? 2
        let width = max(1, Int(ceil(self.bounds.width * scale)))
        let height = max(1, Int(ceil(self.bounds.height * scale)))
        let dark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let headroom = NativeOrbitWarningHDRColor.renderingHeadroom(
            self.window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1, darkAppearance: dark)
        let frame = NativeOrbitWarningHDRRaster.Frame(
            items: self.items, size: self.bounds.size, scale: scale, headroom: headroom, darkAppearance: dark)
        guard frame != self.lastFrame else { return }
        let started = NativeOrbitWarningHDRRaster.presentationTimestamp
        if let layer = self.layer as? CAMetalLayer,
           let device = self.device, let queue = self.commandQueue
        {
            NativeOrbitWarningHDRView.configureDynamicRange(of: layer, sourceHeadroom: headroom)
            layer.contentsScale = scale
            layer.drawableSize = CGSize(width: width, height: height)
            let pixels = NativeOrbitWarningHDRRaster.pixels(
                items: self.items,
                size: self.bounds.size,
                scale: scale,
                headroom: headroom,
                darkAppearance: dark)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            // Intel/AMD GPUs do not support shared textures, even when the GPU has unified memory.
            descriptor.storageMode = device.supportsFamily(.apple1) ? .shared : .managed
            guard let source = device.makeTexture(descriptor: descriptor) else { return }
            let waitStarted = NativeOrbitWarningHDRRaster.presentationTimestamp
            guard let drawable = layer.nextDrawable() else { return }
            let wait = waitStarted.map { (CACurrentMediaTime() - $0) * 1000 } ?? 0
            guard let command = queue.makeCommandBuffer(),
                  let blit = command.makeBlitCommandEncoder()
            else { return }
            pixels.withUnsafeBytes { bytes in
                source.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: bytes.baseAddress!,
                    bytesPerRow: width * 8)
            }
            blit.copy(
                from: source,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: drawable.texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            command.present(drawable)
            command.commit()
            NativeOrbitWarningHDRRaster.recordPresentation(started: started, drawableWait: wait)
        } else {
            self.drawSDRFallback(scale: scale, darkAppearance: dark)
        }
        self.lastFrame = frame
    }

    /// Metal can be unavailable in a remote/headless session. Retain readable, normally coloured symbols there.
    private func drawSDRFallback(scale: CGFloat, darkAppearance: Bool) {
        let image = NSImage(size: self.bounds.size, flipped: true) { rect in
            for item in self.items {
                guard let symbol = NativeOrbitWarningHDRRaster.symbolImage(item.symbol) else { continue }
                let color = item.color.emission(headroom: 1, darkAppearance: darkAppearance)
                let tint = NSColor(
                    srgbRed: Self.sRGB(color.x), green: Self.sRGB(color.y), blue: Self.sRGB(color.z), alpha: 1)
                let tinted = symbol.withSymbolConfiguration(.init(paletteColors: [tint])) ?? symbol
                tinted.draw(in: CGRect(
                    x: rect.midX + item.position.x - symbol.size.width / 2,
                    y: rect.midY + item.position.y - symbol.size.height / 2,
                    width: symbol.size.width,
                    height: symbol.size.height))
            }
            return true
        }
        self.layer?.contentsScale = scale
        self.layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func sRGB(_ linear: Float) -> CGFloat {
        CGFloat(linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055)
    }
}
