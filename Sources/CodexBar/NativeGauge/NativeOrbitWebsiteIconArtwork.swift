import AppKit
import CryptoKit
import Foundation
import ImageIO

/// Turns untrusted website artwork into a bounded, monochrome template.
@MainActor
enum NativeOrbitWebsiteIconArtwork {
    struct Output: Sendable {
        let png: Data
        let svg: Data
        let fingerprint: String
    }

    private static let side = 128
    private static let maximumSourceBytes = 1_048_576
    private nonisolated static let maximumPixels = 16_000_000

    static func make(data: Data, prefersAlpha: Bool) throws -> Output {
        guard !data.isEmpty, data.count <= self.maximumSourceBytes else { throw self.invalidArtwork() }
        var nativeData = data
        // ImageIO metadata is inspected before AppKit is allowed to decode a raster representation.
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") == true {
            nativeData = try SVGValidator.validate(data)
        } else if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            guard (1...64).contains(CGImageSourceGetCount(source)) else { throw self.invalidArtwork() }
            var pixels = 0.0
            for index in 0..<CGImageSourceGetCount(source) {
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
                else { throw Self.invalidArtwork() }
                try Self.validateSize(width: width.doubleValue, height: height.doubleValue)
                pixels += width.doubleValue * height.doubleValue
                guard pixels <= Double(Self.maximumPixels) else { throw Self.invalidArtwork() }
            }
        } else {
            throw Self.invalidArtwork()
        }
        guard let image = NSImage(data: nativeData) else { throw Self.invalidArtwork() }
        try Self.validateSize(width: image.size.width, height: image.size.height)
        let pixels = try Self.sample(image)
        let mask = try Self.normalized(Self.foreground(pixels, prefersAlpha: prefersAlpha))
        let png = try Self.png(mask)
        let path = Self.path(mask)
        let svgText = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"128\" height=\"128\" viewBox=\"0 0 128 128\">"
            + "<path fill=\"black\" d=\"\(path)\"/></svg>"
        let svg = Data(svgText.utf8)
        let fingerprint = SHA256.hash(data: Data(mask)).map { String(format: "%02x", $0) }.joined()
        return Output(png: png, svg: svg, fingerprint: fingerprint)
    }

    private nonisolated static func invalidArtwork() -> CocoaError { CocoaError(.fileReadCorruptFile) }

    private nonisolated static func validateSize(width: Double, height: Double) throws {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 8192, height <= 8192, width * height <= Double(self.maximumPixels)
        else { throw self.invalidArtwork() }
    }

    private static func sample(_ image: NSImage) throws -> [UInt8] {
        let side = Self.side
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: side * 4,
            bitsPerPixel: 32),
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap), let bytes = bitmap.bitmapData
        else { throw Self.invalidArtwork() }
        let scale = Double(side) / max(image.size.width, image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        graphics.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
        image.draw(
            in: NSRect(
                x: (Double(side) - size.width) / 2,
                y: (Double(side) - size.height) / 2,
                width: size.width,
                height: size.height),
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: nil)
        graphics.flushGraphics()
        return Array(UnsafeBufferPointer(start: bytes, count: side * side * 4))
    }

    private static func foreground(_ rgba: [UInt8], prefersAlpha: Bool) throws -> [UInt8] {
        let side = Self.side
        let count = side * side
        var mask = [UInt8](repeating: 0, count: count)
        let visible = (0..<count).filter { rgba[$0 * 4 + 3] >= 96 }
        guard visible.count >= 48 else { throw Self.invalidArtwork() }
        if prefersAlpha {
            for index in visible {
                mask[index] = 1
            }
            return mask
        }
        let border = (0..<count).filter {
            let x = $0 % side
            let y = $0 / side
            return x < 2 || y < 2 || x >= side - 2 || y >= side - 2
        }
        let opaqueBorder = border.filter { rgba[$0 * 4 + 3] >= 230 }
        var background: [Double]?
        if opaqueBorder.count * 10 >= border.count * 9 {
            let candidate = (0..<3).map { channel in
                let values = opaqueBorder.map { Double(rgba[$0 * 4 + channel]) }.sorted()
                return values[values.count / 2]
            }
            let similar = opaqueBorder.filter { Self.distance(rgba, index: $0, color: candidate) < 48 }
            guard similar.count * 10 >= opaqueBorder.count * 9 else { throw Self.invalidArtwork() }
            background = candidate
        }
        let hasColoredOrDarkInk = visible.filter {
            let offset = $0 * 4
            let channels = [rgba[offset], rgba[offset + 1], rgba[offset + 2]]
            return (channels.max() ?? 0) - (channels.min() ?? 0) > 35 || (channels.max() ?? 255) < 170
        }.count * 5 >= visible.count
        for index in visible {
            if let background, Self.distance(rgba, index: index, color: background) < 60 { continue }
            let offset = index * 4
            // White counters inside colored transparent icons must remain holes, just as on a white tile.
            if background == nil, hasColoredOrDarkInk,
               rgba[offset] > 220, rgba[offset + 1] > 220, rgba[offset + 2] > 220 { continue }
            mask[index] = 1
        }
        return mask
    }

    private static func distance(_ rgba: [UInt8], index: Int, color: [Double]) -> Double {
        (0..<3).reduce(0) { $0 + abs(Double(rgba[index * 4 + $1]) - color[$1]) }
    }

    private static func normalized(_ source: [UInt8]) throws -> [UInt8] {
        let side = Self.side
        let ink = source.indices.filter { source[$0] != 0 }
        guard ink.count >= 48,
              let minX = ink.map({ $0 % side }).min(), let maxX = ink.map({ $0 % side }).max(),
              let minY = ink.map({ $0 / side }).min(), let maxY = ink.map({ $0 / side }).max()
        else { throw Self.invalidArtwork() }
        let width = maxX - minX + 1
        let height = maxY - minY + 1
        // Solid tiles and tiny fragments do not provide enough evidence for a recognizable glyph.
        guard width >= 6, height >= 6, max(width, height) <= min(width, height) * 8,
              Double(ink.count) / Double(width * height) < 0.94
        else { throw Self.invalidArtwork() }
        let scale = 112.0 / Double(max(width, height))
        let outputWidth = max(1, Int((Double(width) * scale).rounded()))
        let outputHeight = max(1, Int((Double(height) * scale).rounded()))
        let originX = (side - outputWidth) / 2
        let originY = (side - outputHeight) / 2
        var result = [UInt8](repeating: 0, count: side * side)
        for y in 0..<outputHeight {
            let sourceY = minY + min(height - 1, Int((Double(y) + 0.5) * Double(height) / Double(outputHeight)))
            for x in 0..<outputWidth {
                let sourceX = minX + min(width - 1, Int((Double(x) + 0.5) * Double(width) / Double(outputWidth)))
                result[(originY + y) * side + originX + x] = source[sourceY * side + sourceX]
            }
        }
        return result
    }

    private static func png(_ mask: [UInt8]) throws -> Data {
        let side = Self.side
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: side * 4,
            bitsPerPixel: 32), let bytes = bitmap.bitmapData
        else { throw Self.invalidArtwork() }
        for index in mask.indices {
            bytes[index * 4] = 0
            bytes[index * 4 + 1] = 0
            bytes[index * 4 + 2] = 0
            bytes[index * 4 + 3] = mask[index] == 0 ? 0 : 255
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Self.invalidArtwork() }
        return png
    }

    private static func path(_ mask: [UInt8]) -> String {
        var runs = [String]()
        for y in 0..<Self.side {
            var x = 0
            while x < Self.side {
                guard mask[y * Self.side + x] != 0 else { x += 1; continue }
                let start = x
                while x < Self.side, mask[y * Self.side + x] != 0 {
                    x += 1
                }
                runs.append("M\(start) \(y)h\(x - start)v1H\(start)z")
            }
        }
        return runs.joined()
    }

    /// Deliberately accepts only static, self-contained SVG before passing bytes to native decoding.
    private final class SVGValidator: NSObject, XMLParserDelegate {
        private var valid = true
        private var sawRoot = false
        private var depth = 0
        private var elements = 0
        private var identifierStack = [String?]()
        private var elementStack = [String]()
        private var stylesheet = ""
        private var containsSwitch = false
        private var nodeCosts = ["$document": 0]
        private var references = [String: [String]]()
        private static let allowedElements: Set<String> = [
            "svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "defs", "use",
            "lineargradient", "radialgradient", "stop", "clippath", "mask", "title", "desc", "style", "switch",
        ]

        static func validate(_ data: Data) throws -> Data {
            guard let text = String(data: data, encoding: .utf8)
            else { throw NativeOrbitWebsiteIconArtwork.invalidArtwork() }
            let lower = text.lowercased()
            guard !lower.contains("<!doctype"), !lower.contains("<!entity"), !lower.contains("<?xml-stylesheet"),
                  !lower.contains("\\"), !lower.contains("@"), !lower.contains("<![cdata[")
            else { throw NativeOrbitWebsiteIconArtwork.invalidArtwork() }
            let delegate = SVGValidator()
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse(), delegate.valid, delegate.sawRoot, delegate.depth == 0,
                  delegate.hasBoundedReferences()
            else { throw NativeOrbitWebsiteIconArtwork.invalidArtwork() }
            guard delegate.containsSwitch else { return data }
            // AppKit ignores switch nodes. A single unconditional branch has exactly the semantics of a group.
            let document = try XMLDocument(data: data, options: [])
            for node in try document.nodes(forXPath: "//*[local-name()='switch']") {
                guard let element = node as? XMLElement,
                      let children = element.children?.compactMap({ $0 as? XMLElement }), children.count == 1
                else { throw NativeOrbitWebsiteIconArtwork.invalidArtwork() }
                let conditional = Set(["requiredfeatures", "requiredextensions", "systemlanguage"])
                for candidate in [element, children[0]] {
                    guard !(candidate.attributes ?? []).contains(where: {
                        conditional.contains(($0.name ?? "").lowercased())
                    }) else { throw NativeOrbitWebsiteIconArtwork.invalidArtwork() }
                }
                element.name = "g"
            }
            return document.xmlData
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:])
        {
            let element = elementName.lowercased()
            if element == "switch" { self.containsSwitch = true }
            self.elements += 1
            guard Self.allowedElements.contains(element), self.elements <= 5000,
                  self.depth < 64, self.depth != 0 || element == "svg"
            else { self.reject(parser); return }
            let identifier = attributeDict["id"]
            if let identifier {
                guard Self.fragment("#" + identifier), self.nodeCosts[identifier] == nil
                else { self.reject(parser); return }
                self.nodeCosts[identifier] = 0
            }
            self.identifierStack.append(identifier)
            self.elementStack.append(element)
            for owner in ["$document"] + self.identifierStack.compactMap(\.self) {
                self.nodeCosts[owner, default: 0] += 1
            }
            self.depth += 1
            if !self.sawRoot {
                self.sawRoot = true
                if let widthText = attributeDict["width"], let heightText = attributeDict["height"],
                   let width = Double(widthText.replacingOccurrences(of: "px", with: "")),
                   let height = Double(heightText.replacingOccurrences(of: "px", with: ""))
                {
                    guard (try? NativeOrbitWebsiteIconArtwork.validateSize(width: width, height: height)) != nil
                    else { self.reject(parser); return }
                }
                if let value = attributeDict["viewBox"] ?? attributeDict["viewbox"] {
                    let tokens = value.split { $0.isWhitespace || $0 == "," }
                    let parts = tokens.compactMap { Double($0) }
                    guard tokens.count == 4, parts.count == 4, parts.allSatisfy(\.isFinite),
                          (try? NativeOrbitWebsiteIconArtwork.validateSize(width: parts[2], height: parts[3])) != nil
                    else { self.reject(parser); return }
                }
            }
            for (rawName, rawValue) in attributeDict {
                let name = rawName.lowercased()
                let localName = name.split(separator: ":").last.map(String.init) ?? name
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if localName.hasPrefix("on") || localName == "src" || localName == "base" {
                    self.reject(parser); return
                }
                if localName == "href" {
                    guard Self.fragment(value) else { self.reject(parser); return }
                    self.recordReference(String(value.dropFirst()))
                }
                if name == "xmlns" || name.hasPrefix("xmlns:") {
                    guard value == "http://www.w3.org/2000/svg" || value == "http://www.w3.org/1999/xlink" ||
                        value == "http://www.w3.org/XML/1998/namespace"
                    else { self.reject(parser); return }
                }
                guard Self.safeCSS(value) else { self.reject(parser); return }
                for target in Self.cssReferences(value) {
                    self.recordReference(target)
                }
                if element == "svg", name == "width" || name == "height" {
                    let numeric = value.replacingOccurrences(of: "px", with: "")
                    guard let dimension = Double(numeric), dimension > 0, dimension <= 8192
                    else { self.reject(parser); return }
                }
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?)
        {
            if self.elementStack.last == "style" {
                guard Self.safeCSS(self.stylesheet) else { self.reject(parser); return }
                for target in Self.cssReferences(self.stylesheet) {
                    self.recordReference(target)
                }
                self.stylesheet = ""
            }
            self.depth -= 1
            if !self.identifierStack.isEmpty { self.identifierStack.removeLast() }
            if !self.elementStack.isEmpty { self.elementStack.removeLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if self.elementStack.last == "style" { self.stylesheet += string }
        }

        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            self.reject(parser)
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            self.reject(parser)
            return nil
        }

        private func recordReference(_ target: String) {
            for owner in ["$document"] + self.identifierStack.compactMap(\.self) {
                self.references[owner, default: []].append(target)
            }
        }

        private func hasBoundedReferences() -> Bool {
            var active = Set<String>()
            var costs = [String: Int]()
            func cost(_ identifier: String) -> Int? {
                if let cached = costs[identifier] { return cached }
                guard active.count < 32, !active.contains(identifier), var total = self.nodeCosts[identifier]
                else { return nil }
                active.insert(identifier)
                defer { active.remove(identifier) }
                for target in self.references[identifier, default: []] {
                    guard let expansion = cost(target), total <= 20000 - expansion else { return nil }
                    total += expansion
                }
                costs[identifier] = total
                return total
            }
            return cost("$document") != nil
        }

        private static func cssReferences(_ value: String) -> [String] {
            var references = [String]()
            var remainder = value[...]
            while let range = remainder.range(of: "url", options: .caseInsensitive) {
                remainder = remainder[range.upperBound...].drop(while: \.isWhitespace)
                guard let end = remainder.firstIndex(of: ")") else { break }
                let target = remainder[..<end].filter { !"(\"'".contains($0) && !$0.isWhitespace }
                references.append(String(target.dropFirst()))
                remainder = remainder[remainder.index(after: end)...]
            }
            return references
        }

        private func reject(_ parser: XMLParser) {
            self.valid = false
            parser.abortParsing()
        }

        private static func fragment(_ value: String) -> Bool {
            guard value.hasPrefix("#"), value.count > 1 else { return false }
            return value.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || "_-.:".contains($0) }
        }

        private static func safeCSS(_ value: String) -> Bool {
            let lower = value.lowercased()
            guard !lower.contains("@"), !lower.contains("\\"), !lower.contains("/*"),
                  !lower.contains("javascript:"), !lower.contains("expression(")
            else { return false }
            var remainder = lower[...]
            while let range = remainder.range(of: "url", options: .caseInsensitive) {
                remainder = remainder[range.upperBound...].drop(while: \.isWhitespace)
                guard remainder.first == "(", let end = remainder.firstIndex(of: ")") else { return false }
                var target = String(remainder[remainder.index(after: remainder.startIndex)..<end])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if (target.hasPrefix("'") && target.hasSuffix("'")) ||
                    (target.hasPrefix("\"") && target.hasSuffix("\""))
                { target = String(target.dropFirst().dropLast())
                }
                guard Self.fragment(target) else { return false }
                remainder = remainder[remainder.index(after: end)...]
            }
            return true
        }
    }
}
