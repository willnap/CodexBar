import AppKit
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitWarningLayoutTests {
    typealias Kind = NativeOrbitWarningLight.Kind

    @Test func `identity reservations match the actual fixed marks at each size`() {
        for lanes in 1...3 {
            let size = lanes == 3 ? CGSize(width: 28, height: 22) : CGSize(width: 42, height: 34)
            let expected = [
                CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                CGRect(x: -7.5, y: (lanes == 3 ? -24 : -34) - 7.5, width: 15, height: 15),
                CGRect(x: -8.5, y: (lanes == 3 ? 24 : 44) - 8.5, width: 17, height: 17),
            ]
            #expect(NativeOrbitWarningLayout.identityReservations(
                lanes: lanes, hasCompany: true, hasBadge: true) == expected)
        }
    }

    @Test func `the full warning map has an even neighbour pitch without nearly shared slots`() throws {
        for lanes in 1...3 {
            let positions = Dictionary(uniqueKeysWithValues: Kind.allCases.map {
                ($0, NativeOrbitWarningLayout.preferred($0, lanes: lanes))
            })
            let scale = NativeOrbitWarningLayout.radius(lanes: lanes) / NativeOrbitWarningLayout.radius(lanes: 3)
            let distances = try Kind.allCases.map { kind in
                let p = try #require(positions[kind])
                return try Kind.allCases.filter { $0 != kind }.map { other in
                    let q = try #require(positions[other])
                    return hypot(p.x - q.x, p.y - q.y) / scale
                }.min() ?? 0
            }
            let shortest = try #require(distances.min()), longest = try #require(distances.max())
            #expect(shortest >= 7.49, "Two lamps almost share a slot: \(shortest) pt")
            #expect(longest / shortest <= 1.3, "Uneven neighbour pitch: \(shortest)...\(longest) pt")
        }
    }

    @Test func `actual dense layouts keep a consistent pitch with and without fixed identity marks`() throws {
        for fixedIdentity in [false, true] {
            let reservations = fixedIdentity ? NativeOrbitWarningLayout.identityReservations(
                lanes: 3, hasCompany: true, hasBadge: true) : []
            let positions = NativeOrbitWarningLayout.positions(
                for: Kind.allCases, lanes: 3, reservedRegions: reservations)
            let distances = try Kind.allCases.map { kind in
                let p = try #require(positions[kind])
                return try Kind.allCases.filter { $0 != kind }.map { other in
                    let q = try #require(positions[other])
                    return hypot(p.x - q.x, p.y - q.y)
                }.min() ?? 0
            }
            let shortest = try #require(distances.min()), longest = try #require(distances.max())
            #expect(shortest >= (fixedIdentity ? 4 : 7.4), "Near-shared slots: \(shortest)")
            #expect(longest / shortest <= (fixedIdentity ? 1.6 : 1.3), "Uneven pitch: \(shortest)...\(longest)")
        }
    }

    @Test func `every ideal location has identical relative coordinates at every ring count`() {
        for kind in Kind.allCases {
            let reference = NativeOrbitWarningLayout.preferred(kind, lanes: 3)
            let r = NativeOrbitWarningLayout.radius(lanes: 3)
            #expect(NativeOrbitWarningLayout.inCategoryNeighbourhood(reference, category: kind.category, radius: r))
            for lanes in 1...2 {
                let p = NativeOrbitWarningLayout.preferred(kind, lanes: lanes)
                let scale = NativeOrbitWarningLayout.radius(lanes: lanes) / r
                #expect(abs(p.x - reference.x * scale) < 0.00001, "\(kind)")
                #expect(abs(p.y - reference.y * scale) < 0.00001, "\(kind)")
            }
        }
    }

    @Test func `active padding keeps each warning in its proportional home neighbourhood`() throws {
        let sets: [[Kind]] = [
            Kind.allCases,
            [.limit, .oldReading, .signIn, .rateLimited, .maintenance, .helper],
            [.signIn, .keychain, .wrongAccount, .permission, .browserSession, .macOffline],
        ]
        for kinds in sets {
            for lanes in 1...3 {
                let positions = NativeOrbitWarningLayout.positions(for: kinds, lanes: lanes)
                let scale = NativeOrbitWarningLayout.radius(lanes: lanes) / NativeOrbitWarningLayout.radius(lanes: 3)
                for kind in kinds {
                    let p = try #require(positions[kind])
                    let home = NativeOrbitWarningLayout.preferred(kind, lanes: lanes)
                    #expect(hypot(p.x - home.x, p.y - home.y) / scale <= 13.01, "\(kind), \(lanes)")
                }
            }
        }
    }

    @Test func `the largest dial separates all fifty one actual glyphs using the available room`() throws {
        let positions = NativeOrbitWarningLayout.positions(for: Kind.allCases, lanes: 1)
        for (index, kind) in Kind.allCases.enumerated() {
            let p = try #require(positions[kind])
            let ink = NativeOrbitWarningLayout.inkBounds(kind).offsetBy(dx: p.x, dy: p.y)
            for other in Kind.allCases.dropFirst(index + 1) {
                let q = try #require(positions[other])
                let otherInk = NativeOrbitWarningLayout.inkBounds(other).offsetBy(dx: q.x, dy: q.y)
                #expect(!ink.insetBy(dx: -0.7, dy: -0.7).intersects(otherInk), "\(kind), \(other)")
            }
        }
    }

    @Test func `medium dial boundary sets use spare room before relaxing ink clearance`() throws {
        for count in [40, 44, 48] {
            let kinds = Array(Kind.allCases.prefix(count))
            let positions = NativeOrbitWarningLayout.positions(for: kinds, lanes: 2)
            for (index, kind) in kinds.enumerated() {
                let p = try #require(positions[kind])
                let ink = NativeOrbitWarningLayout.inkBounds(kind).offsetBy(dx: p.x, dy: p.y)
                for other in kinds.dropFirst(index + 1) {
                    let q = try #require(positions[other])
                    let otherInk = NativeOrbitWarningLayout.inkBounds(other).offsetBy(dx: q.x, dy: q.y)
                    let overlap = ink.intersection(otherInk)
                    #expect(
                        overlap.isNull || min(overlap.width, overlap.height) < 0.01,
                        "\(count) lamps: \(kind), \(other), overlap \(overlap)")
                }
            }
        }
    }

    @Test func `spacing adjustments stay local to the category homes even with all lights on`() throws {
        let positions = NativeOrbitWarningLayout.positions(for: Kind.allCases, lanes: 3)
        for kind in Kind.allCases {
            let p = try #require(positions[kind])
            let home = NativeOrbitWarningLayout.preferred(kind, lanes: 3)
            #expect(hypot(p.x - home.x, p.y - home.y) <= 11.01, "\(kind) left its neighbourhood")
        }
        #expect(Kind.unpriced.category == "reading")
        #expect(Kind.autoRefreshOff.category == "codexbar")
        #expect(Kind.overloaded.category == "service")
    }

    @Test func `every icon retains readable unshared ink in the fifty one light stress view`() throws {
        let kinds = Kind.allCases
        let positions = NativeOrbitWarningLayout.positions(for: kinds, lanes: 3)
        let side = 192
        var owners = [Int](repeating: 0, count: side * side)
        let masks = try kinds.map { kind in
            let p = try #require(positions[kind])
            let pixels = NativeOrbitWarningHDRRaster.pixels(
                items: [.init(id: kind.catalogueKey, symbol: kind.symbol, position: p, color: .caution)],
                size: CGSize(width: 96, height: 96),
                scale: 2,
                headroom: 1,
                darkAppearance: false)
            let occupied = (0..<(side * side)).filter { pixels[$0 * 4 + 3] > 0.45 }
            for pixel in occupied {
                owners[pixel] += 1
            }
            return occupied
        }
        for (index, mask) in masks.enumerated() {
            let free = mask.filter { owners[$0] == 1 }.count
            #expect(Double(free) / Double(max(1, mask.count)) >= 0.4, "\(kinds[index]) is obscured")
        }
    }

    @Test func `bulb check includes the green opportunity lights and every actual glyph`() throws {
        let lights = NativeOrbitWarningLightsView.bulbCheck
        #expect(lights.count == 51)
        let green: Set<Kind> = [
            .behindPace,
            .idle,
            .earlyReset,
            .newSavedReset,
            .timeZone,
            .autoRefreshOff,
            .maintenance,
            .update,
        ]
        #expect(Set(lights.filter { $0.severity == .opportunity }.map(\.kind)) == green)
        for light in lights {
            let image = try #require(NativeOrbitWarningHDRRaster.symbolImage(light.kind.symbol), "\(light.kind)")
            #expect(image.size.width > 0 && image.size.height > 0)
            let pixels = NativeOrbitWarningHDRRaster.pixels(
                items: [.init(
                    id: light.kind.catalogueKey,
                    symbol: light.kind.symbol,
                    position: .zero,
                    color: .opportunity)],
                size: CGSize(width: 64, height: 64),
                scale: 2,
                headroom: 2,
                darkAppearance: false)
            #expect(pixels.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 }, "\(light.kind)")
        }
    }

    @Test(arguments: [1, 2, 3])
    func `a lone light stays at its preferred position at thirteen points`(lanes: Int) throws {
        let positions = NativeOrbitWarningLayout.positions(for: [.quota], lanes: lanes)
        #expect(positions[.quota] == NativeOrbitWarningLayout.preferred(.quota, lanes: lanes))
        #expect(NativeOrbitWarningLightsView.size(lanes: lanes) == 13)
        let fuel = try #require(positions[.quota])
        #expect(fuel.x < 0 && fuel.y > 0)
    }

    @Test(arguments: [1, 2, 3])
    func `a timezone light avoids the centered monetary reading`(lanes: Int) throws {
        let reserved = self.moneyBounds(lanes: lanes)
        let ordinary = NativeOrbitWarningLayout.positions(for: [.timeZone], lanes: lanes)
        let positions = NativeOrbitWarningLayout.positions(for: [.timeZone], lanes: lanes, reservedBounds: reserved)
        let point = try #require(positions[.timeZone])
        let ink = NativeOrbitWarningLayout.inkBounds(.timeZone).offsetBy(dx: point.x, dy: point.y)
        #expect(!ink.intersects(reserved.insetBy(
            dx: -NativeOrbitWarningLayout.padding, dy: -NativeOrbitWarningLayout.padding)))
        #expect(ordinary == NativeOrbitWarningLayout.positions(for: [.timeZone], lanes: lanes))
    }

    @Test(arguments: [1, 2, 3])
    func `several warnings keep clear of centered money and each other`(lanes: Int) throws {
        let reserved = self.moneyBounds(lanes: lanes)
        let kinds: [Kind] = [.timeZone, .quota, .signIn, .autoRefreshOff]
        let positions = NativeOrbitWarningLayout.positions(for: kinds, lanes: lanes, reservedBounds: reserved)
        let radius = NativeOrbitWarningLayout.radius(lanes: lanes)
        for (index, kind) in kinds.enumerated() {
            let point = try #require(positions[kind])
            let ink = NativeOrbitWarningLayout.inkBounds(kind).offsetBy(dx: point.x, dy: point.y)
            #expect(!ink.intersects(reserved.insetBy(
                dx: -NativeOrbitWarningLayout.padding, dy: -NativeOrbitWarningLayout.padding)))
            for corner in [
                CGPoint(x: ink.minX, y: ink.minY), CGPoint(x: ink.maxX, y: ink.minY),
                CGPoint(x: ink.minX, y: ink.maxY), CGPoint(x: ink.maxX, y: ink.maxY),
            ] {
                #expect(hypot(corner.x, corner.y) < radius)
            }
            for other in kinds.dropFirst(index + 1) {
                let otherPoint = try #require(positions[other])
                let otherInk = NativeOrbitWarningLayout.inkBounds(other)
                    .offsetBy(dx: otherPoint.x, dy: otherPoint.y)
                #expect(!ink.insetBy(dx: -0.75, dy: -0.75).intersects(otherInk), "\(kind), \(other)")
            }
        }
        #expect(positions == NativeOrbitWarningLayout.positions(
            for: kinds.reversed(), lanes: lanes, reservedBounds: reserved))
    }

    @Test func `money avoidance only adds local spacing to the necessary clearing move`() throws {
        let kinds: [Kind] = [.timeZone, .limit, .signIn, .autoRefreshOff]
        for lanes in 1...3 {
            let positions = NativeOrbitWarningLayout.positions(
                for: kinds, lanes: lanes, reservedBounds: self.moneyBounds(lanes: lanes))
            let scale = NativeOrbitWarningLayout.radius(lanes: lanes) / NativeOrbitWarningLayout.radius(lanes: 3)
            for kind in kinds {
                let p = try #require(positions[kind])
                let ideal = NativeOrbitWarningLayout.preferred(kind, lanes: lanes)
                let solo = try #require(NativeOrbitWarningLayout.positions(
                    for: [kind], lanes: lanes, reservedBounds: self.moneyBounds(lanes: lanes))[kind])
                let clearing = hypot(solo.x - ideal.x, solo.y - ideal.y)
                #expect(hypot(p.x - ideal.x, p.y - ideal.y) <= clearing + 13.01 * scale, "\(kind)")
                if abs(ideal.x) > NativeOrbitWarningLayout.radius(lanes: lanes) * 0.2 {
                    #expect(p.x * ideal.x >= 0, "\(kind) crossed to the other side of the dial")
                }
            }
        }
    }

    @Test func `a money reading leaves an unobstructed lone light at its exact ideal home`() {
        for lanes in 1...3 {
            let positions = NativeOrbitWarningLayout.positions(
                for: [.outage], lanes: lanes, reservedBounds: self.moneyBounds(lanes: lanes))
            #expect(positions[.outage] == NativeOrbitWarningLayout.preferred(.outage, lanes: lanes))
        }
    }

    @Test func `fixed identity marks clear every feasible lone warning and minimise the widest glyph overlap`() throws {
        for lanes in 1...3 {
            let reservations = NativeOrbitWarningLayout.identityReservations(
                lanes: lanes,
                hasCompany: true,
                hasBadge: true)
            for kind in Kind.allCases {
                let positions = NativeOrbitWarningLayout.positions(
                    for: [kind],
                    lanes: lanes,
                    reservedRegions: reservations)
                let point = try #require(positions[kind])
                let ink = NativeOrbitWarningLayout.inkBounds(kind).offsetBy(dx: point.x, dy: point.y)
                if kind == .overloaded {
                    let home = NativeOrbitWarningLayout.preferred(kind, lanes: lanes)
                    let oldOverlap = NativeOrbitWarningLayout.reservationOverlap(
                        home,
                        bounds: NativeOrbitWarningLayout.inkBounds(kind),
                        reservations: reservations)
                    let overlap = NativeOrbitWarningLayout.reservationOverlap(
                        point,
                        bounds: NativeOrbitWarningLayout.inkBounds(kind),
                        reservations: reservations)
                    #expect(oldOverlap == 0 ? overlap == 0 : overlap < oldOverlap, "\(kind), \(lanes)")
                } else {
                    #expect(reservations.allSatisfy { !ink.intersects($0) }, "\(kind), \(lanes)")
                }
            }
        }
    }

    private func moneyBounds(lanes: Int) -> CGRect {
        let sizes = [
            CGSize(width: 144, height: 52), CGSize(width: 106, height: 41), CGSize(width: 65, height: 25),
        ]
        let size = sizes[lanes - 1]
        return CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    }

    @Test(arguments: [1, 2, 3])
    func `nearby active warnings separate their padded ink without shrinking`(lanes: Int) throws {
        let kinds: [Kind] = [.quota, .oldReading, .signIn, .rateLimited, .maintenance, .helper]
        let positions = NativeOrbitWarningLayout.positions(for: kinds, lanes: lanes)
        for (index, a) in kinds.enumerated() {
            let pa = try #require(positions[a])
            let ra = NativeOrbitWarningLayout.inkBounds(a).offsetBy(dx: pa.x, dy: pa.y)
            for b in kinds.dropFirst(index + 1) {
                let pb = try #require(positions[b])
                let rb = NativeOrbitWarningLayout.inkBounds(b).offsetBy(dx: pb.x, dy: pb.y)
                #expect(!ra.insetBy(dx: -0.75, dy: -0.75).intersects(rb), "\(a), \(b)")
            }
        }
    }

    @Test(arguments: [1, 2, 3])
    func `all fifty one remain distinct and inside the ring in the stress view`(lanes: Int) throws {
        let kinds = Kind.allCases
        let positions = NativeOrbitWarningLayout.positions(for: kinds, lanes: lanes)
        #expect(positions.count == 51)
        #expect(Set(positions.values.map { "\($0.x),\($0.y)" }).count == 51)
        let radius: CGFloat = [83.53125, 61.59375, 39.65625][lanes - 1]
        for kind in kinds {
            let p = try #require(positions[kind])
            let r = NativeOrbitWarningLayout.inkBounds(kind).offsetBy(dx: p.x, dy: p.y)
            for corner in [
                CGPoint(x: r.minX, y: r.minY),
                CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.minX, y: r.maxY),
                CGPoint(x: r.maxX, y: r.maxY),
            ] {
                #expect(hypot(corner.x, corner.y) < radius, "\(kind) leaves the inner ring")
            }
        }
    }

    @Test func `input ordering does not move the lights and duplicate warnings do not reserve extra space`() {
        let kinds: [Kind] = [.signIn, .quota, .oldReading, .rateLimited]
        let first = NativeOrbitWarningLayout.positions(for: kinds, lanes: 3)
        #expect(first == NativeOrbitWarningLayout.positions(for: kinds.reversed(), lanes: 3))
        #expect(first == NativeOrbitWarningLayout.positions(for: kinds + [.quota], lanes: 3))
        #expect(NativeOrbitWarningLayout.positions(for: [], lanes: 3).isEmpty)
    }

    @Test(arguments: [1, 2, 3])
    func `every pair of lights has room without an ink collision`(lanes: Int) throws {
        for (index, a) in Kind.allCases.enumerated() {
            for b in Kind.allCases.dropFirst(index + 1) {
                let positions = NativeOrbitWarningLayout.positions(for: [a, b], lanes: lanes)
                let pa = try #require(positions[a]), pb = try #require(positions[b])
                let ra = NativeOrbitWarningLayout.inkBounds(a).offsetBy(dx: pa.x, dy: pa.y)
                let rb = NativeOrbitWarningLayout.inkBounds(b).offsetBy(dx: pb.x, dy: pb.y)
                #expect(!ra.insetBy(dx: -0.75, dy: -0.75).intersects(rb), "\(a), \(b), \(lanes) rings")
            }
        }
    }
}
