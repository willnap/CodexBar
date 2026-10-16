import AppKit
import XCTest
@testable import CodexBar

@MainActor
final class NativeOrbitWebsiteIconArtworkTests: XCTestCase {
    func testNativeSVGDecodeProducesMatchingPurePathAndPNG() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
        <defs><linearGradient id="paint"><stop stop-color="#2563eb"/>
        <stop offset="1" stop-color="#ef4444"/></linearGradient>
        <path id="ring" d="M8 8H56V56H8Z M20 20V44H44V20Z"/></defs>
        <use href="#ring" fill="url(#paint)" fill-rule="evenodd"/></svg>
        """
        let output = try NativeOrbitWebsiteIconArtwork.make(data: Data(svg.utf8), prefersAlpha: false)
        let text = try XCTUnwrap(String(data: output.svg, encoding: .utf8))
        XCTAssertTrue(text.contains("<path"))
        XCTAssertFalse(text.contains("<image"))
        XCTAssertEqual(output.fingerprint.count, 64)
        let pixels = try self.pixels(output.png)
        XCTAssertEqual(pixels.width, 128)
        XCTAssertEqual(pixels.alpha(64, 64), 0, "The counter remains open")
        XCTAssertGreaterThan(pixels.alpha(20, 20), 0)
        let roundTrip = try NativeOrbitWebsiteIconArtwork.make(data: output.svg, prefersAlpha: true)
        XCTAssertEqual(roundTrip.fingerprint, output.fingerprint)
    }

    func testTransparentMonochromeAlphaAndPaddingNormalizeDeterministically() throws {
        let first = try self.fixture(size: 64, opaque: false) { context in
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 8, y: 8, width: 48, height: 12))
            context.fill(CGRect(x: 26, y: 8, width: 12, height: 48))
        }
        let padded = try self.fixture(size: 128, opaque: false) { context in
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 16, y: 16, width: 96, height: 24))
            context.fill(CGRect(x: 52, y: 16, width: 24, height: 96))
        }
        let a = try NativeOrbitWebsiteIconArtwork.make(data: first, prefersAlpha: true)
        let b = try NativeOrbitWebsiteIconArtwork.make(data: padded, prefersAlpha: true)
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        XCTAssertEqual(a.png, try NativeOrbitWebsiteIconArtwork.make(data: first, prefersAlpha: true).png)
    }

    func testOpaqueTilePreservesWhiteCounterInsideColoredSymbol() throws {
        let data = try self.fixture(size: 64, opaque: true) { context in
            context.setFillColor(NSColor.systemBlue.cgColor)
            context.fill(CGRect(x: 8, y: 8, width: 48, height: 48))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 22, y: 22, width: 20, height: 20))
        }
        let output = try NativeOrbitWebsiteIconArtwork.make(data: data, prefersAlpha: false)
        let pixels = try self.pixels(output.png)
        XCTAssertEqual(pixels.alpha(64, 64), 0)
        XCTAssertGreaterThan(pixels.alpha(22, 22), 0)
        XCTAssertEqual(pixels.alpha(0, 0), 0)
    }

    func testOpaqueThreeTileWordmarkPreservesWhiteLettersAndTheirBlackCounters() throws {
        let data = try self.fixture(size: 128, opaque: true) { context in
            for origin in [8, 48, 88] {
                context.setFillColor(NSColor.black.cgColor)
                context.fill(CGRect(x: origin, y: 48, width: 32, height: 32))
            }
            for origin in [20, 60] {
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(x: origin, y: 54, width: 14, height: 20))
                context.setFillColor(NSColor.black.cgColor)
                context.fill(CGRect(x: origin + 5, y: 58, width: 5, height: 5))
                context.fill(CGRect(x: origin + 5, y: 66, width: 5, height: 5))
            }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 98, y: 54, width: 14, height: 20))
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 103, y: 59, width: 9, height: 10))
        }
        let output = try NativeOrbitWebsiteIconArtwork.make(data: data, prefersAlpha: false)
        let pixels = try self.pixels(output.png)
        XCTAssertEqual(pixels.alpha(22, 64), 0, "White letter stem remains open in the template")
        XCTAssertGreaterThan(pixels.alpha(27, 61), 0, "Black counter inside the white letter remains ink")
        XCTAssertEqual(pixels.alpha(100, 64), 0)
        XCTAssertGreaterThan(pixels.alpha(107, 64), 0)
        XCTAssertGreaterThan(pixels.alpha(12, 70), 0)
        let roundTrip = try NativeOrbitWebsiteIconArtwork.make(data: output.svg, prefersAlpha: true)
        XCTAssertEqual(output.fingerprint, roundTrip.fingerprint)
    }

    func testTransparentColoredSymbolPreservesWhiteCounter() throws {
        let data = try self.fixture(size: 64, opaque: false) { context in
            context.setFillColor(NSColor.systemRed.cgColor)
            context.fill(CGRect(x: 8, y: 8, width: 48, height: 48))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 22, y: 22, width: 20, height: 20))
        }
        let output = try NativeOrbitWebsiteIconArtwork.make(data: data, prefersAlpha: false)
        let pixels = try self.pixels(output.png)
        XCTAssertEqual(pixels.alpha(64, 64), 0)
        XCTAssertGreaterThan(pixels.alpha(22, 22), 0)
    }

    func testOpaqueColoredBackgroundExtractsContrastingWhiteGlyph() throws {
        let data = try self.fixture(size: 64, opaque: true) { context in
            context.setFillColor(NSColor.systemBlue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 8, y: 8, width: 48, height: 12))
            context.fill(CGRect(x: 26, y: 8, width: 12, height: 48))
        }
        let output = try NativeOrbitWebsiteIconArtwork.make(data: data, prefersAlpha: false)
        let pixels = try self.pixels(output.png)
        XCTAssertEqual(pixels.alpha(0, 0), 0)
        XCTAssertGreaterThan(pixels.alpha(64, 64), 0)
    }

    func testStaticClipAndMaskAreAccepted() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
        <defs><clipPath id="clip"><circle cx="32" cy="32" r="28"/></clipPath>
        <mask id="mask"><rect width="64" height="64" fill="white"/>
        <circle cx="32" cy="32" r="12" fill="black"/></mask></defs>
        <rect width="64" height="64" fill="red" clip-path="url(#clip)" mask="url(#mask)"/></svg>
        """
        let output = try NativeOrbitWebsiteIconArtwork.make(data: Data(svg.utf8), prefersAlpha: false)
        let pixels = try self.pixels(output.png)
        XCTAssertEqual(pixels.alpha(64, 64), 0)
        XCTAssertGreaterThan(pixels.alpha(64, 20), 0)
    }

    func testRejectsExcessiveFragmentExpansionBeforeNativeDecode() {
        var svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'><defs>"
        svg += "<g id='n0'><path d='M8 8H56V20H36V56H24V20H8Z'/></g>"
        for index in 1...16 {
            svg += "<g id='n\(index)'><use href='#n\(index - 1)'/><use href='#n\(index - 1)'/></g>"
        }
        // Unused definitions make this a safe regression fixture for the validator's expansion budget.
        svg += "</defs><path d='M8 8H56V20H36V56H24V20H8Z'/></svg>"
        XCTAssertThrowsError(try NativeOrbitWebsiteIconArtwork.make(data: Data(svg.utf8), prefersAlpha: false))
    }

    func testTransparentGlyphCanTouchCanvasEdges() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
        <path d="M0 8H12V52H52V8H64V64H0Z"/></svg>
        """
        let output = try NativeOrbitWebsiteIconArtwork.make(data: Data(svg.utf8), prefersAlpha: false)
        XCTAssertEqual(try self.pixels(output.png).alpha(64, 32), 0)
    }

    func testStaticSwitchContainerPreservesNativeSilhouetteAndValidatesEveryChild() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" xml:space="preserve" viewBox="0 0 64 64">
        <switch><g><linearGradient id="paint"><stop stop-color="red"/>
        <stop offset="1" stop-color="blue"/></linearGradient>
        <path fill="url(#paint)" d="M8 8H56V20H38V56H26V20H8Z"/></g></switch></svg>
        """
        let output = try NativeOrbitWebsiteIconArtwork.make(data: Data(svg.utf8), prefersAlpha: false)
        let roundTrip = try NativeOrbitWebsiteIconArtwork.make(data: output.svg, prefersAlpha: true)
        XCTAssertEqual(output.fingerprint, roundTrip.fingerprint)
        for child in ["<foreignObject/>", "<script/>", "<path onload='run()'/>", "<g/>"] {
            let unsafe = svg.replacingOccurrences(of: "</switch>", with: child + "</switch>")
            XCTAssertThrowsError(try NativeOrbitWebsiteIconArtwork.make(data: Data(unsafe.utf8), prefersAlpha: false))
        }
        let conditional = svg.replacingOccurrences(of: "<g>", with: "<g systemLanguage='zz'>")
        XCTAssertThrowsError(try NativeOrbitWebsiteIconArtwork.make(data: Data(conditional.utf8), prefersAlpha: false))
    }

    func testRejectsExternalHrefThroughNamespaceAliasBeforeNativeDecode() {
        // A path does not dereference href in AppKit, so this regression never triggers a network request.
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:q="http://www.w3.org/1999/xlink" viewBox="0 0 64 64">
        <path q:href="https://remote.example/icon.svg#x" d="M8 8H56V20H38V56H26V20H8Z"/></svg>
        """
        XCTAssertThrowsError(try NativeOrbitWebsiteIconArtwork.make(data: Data(svg.utf8), prefersAlpha: false))
        for attribute in ["q:onload='run()'", "q:base='https://remote.example/'"] {
            let unsafe = svg.replacingOccurrences(of: "q:href=\"https://remote.example/icon.svg#x\"", with: attribute)
            XCTAssertThrowsError(try NativeOrbitWebsiteIconArtwork.make(data: Data(unsafe.utf8), prefersAlpha: false))
        }
        let unknownNamespace = svg.replacingOccurrences(of: "http://www.w3.org/1999/xlink", with: "urn:unknown")
        XCTAssertThrowsError(try NativeOrbitWebsiteIconArtwork.make(
            data: Data(unknownNamespace.utf8),
            prefersAlpha: false))
        let externalUse = svg.replacingOccurrences(of: "<path q:href", with: "<use q:href")
        XCTAssertThrowsError(try NativeOrbitWebsiteIconArtwork.make(data: Data(externalUse.utf8), prefersAlpha: false))
    }

    func testRejectsUnsafeAndMalformedSVG() {
        let payloads = [
            "<svg><script>alert(1)</script></svg>",
            "<svg onload='x()'><path d='M0 0H20V20Z'/></svg>",
            "<svg><foreignObject/></svg>", "<svg><image href='https://example.com/a.png'/></svg>",
            "<svg><use href='file:///etc/passwd'/></svg>",
            "<svg><style>@import 'https://example.com/a.css';</style></svg>",
            "<svg><path style='fill:url(https://example.com/a)'/></svg>",
            "<svg><animate attributeName='d'/></svg>",
            "<svg><style>.a { fill: url(https://example.com/a); }</style></svg>",
            "<svg><style>.a { fill: u&#114;l(https://example.com/a); }</style></svg>",
            "<svg><path fill='u&#114;l(https://example.com/a)'/></svg>",
            "<svg><defs><g id='cycle'><use href='#cycle'/></g></defs></svg>",
            "<svg viewBox='0 0 bad 64 64'><path d='M0 0H20V20Z'/></svg>",
            "<!DOCTYPE svg [<!ENTITY a 'x'>]><svg>&a;</svg>", "<svg><path></svg>",
            "<svg width='9000' height='9000'><path d='M0 0H20V20Z'/></svg>",
        ]
        for value in payloads {
            XCTAssertThrowsError(
                try NativeOrbitWebsiteIconArtwork.make(data: Data(value.utf8), prefersAlpha: false),
                value)
        }
    }

    func testRejectsEmptySolidAndLowDetailImages() throws {
        let empty = try self.fixture(size: 64, opaque: false) { _ in }
        let solid = try self.fixture(size: 64, opaque: true) { _ in }
        let rectangle = try self.fixture(size: 64, opaque: false) { context in
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 4, y: 4, width: 56, height: 56))
        }
        for data in [empty, solid, rectangle] {
            XCTAssertThrowsError(try NativeOrbitWebsiteIconArtwork.make(data: data, prefersAlpha: true))
        }
        XCTAssertThrowsError(try NativeOrbitWebsiteIconArtwork.make(
            data: Data(repeating: 0, count: 1_048_577),
            prefersAlpha: false))
    }

    func testRejectsOversizedRasterBeforeRendering() throws {
        let data = try self.fixture(size: 4097, opaque: true) { _ in }
        XCTAssertLessThan(data.count, 1_048_576)
        XCTAssertThrowsError(try NativeOrbitWebsiteIconArtwork.make(data: data, prefersAlpha: false))
    }

    private func fixture(size: Int, opaque: Bool, draw: (CGContext) -> Void) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: size * 4,
            bitsPerPixel: 32))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let context = graphics.cgContext
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        if opaque {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
        draw(context)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func pixels(_ data: Data) throws -> Pixels {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        return Pixels(rep: rep)
    }

    private struct Pixels {
        let rep: NSBitmapImageRep
        var width: Int {
            self.rep.pixelsWide
        }

        func alpha(_ x: Int, _ y: Int) -> Int { Int((self.rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255) }
    }
}
