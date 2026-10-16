import AppKit

/// Semantic home positions with local breathing room. Only illuminated lamps reserve space.
/// The symbol size never participates in density adaptation: crowded layouts yield padding before glyphs.
@MainActor
enum NativeOrbitWarningLayout {
    typealias Kind = NativeOrbitWarningLight.Kind
    static let padding: CGFloat = 1.5
    private static var inkCache: [Kind: CGRect] = [:]
    private static var layoutCache: [String: [Kind: CGPoint]] = [:]

    static func radius(lanes: Int) -> CGFloat {
        let lane = min(3, max(1, lanes)) - 1
        return (NativeOrbitSymbol.radii[lane] - NativeOrbitSymbol.stroke / 2) * 216 / 256
    }

    /// The measured coverage, rather than the transparent alignment margins in an SF Symbol image.
    static func inkBounds(_ kind: Kind) -> CGRect {
        if let cached = self.inkCache[kind] { return cached }
        guard let image = NativeOrbitWarningHDRRaster.symbolImage(kind.symbol) else {
            return CGRect(x: -6.5, y: -6.5, width: 13, height: 13)
        }
        let scale: CGFloat = 4
        let width = Int(ceil(image.size.width * scale)), height = Int(ceil(image.size.height * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            image.draw(
                in: CGRect(origin: .zero, size: image.size),
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let bounds = maxX >= minX ? CGRect(
            x: CGFloat(minX) / scale - image.size.width / 2,
            y: CGFloat(minY) / scale - image.size.height / 2,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale) : CGRect(x: -6.5, y: -6.5, width: 13, height: 13)
        self.inkCache[kind] = bounds
        return bounds
    }

    /// One map is contained against the tightest centre once, then scaled uniformly for every dial.
    static func preferred(_ kind: Kind, lanes: Int) -> CGPoint {
        let home = NativeOrbitWarningBulbPositions.homes[kind.catalogueKey] ?? .zero
        let referenceRadius = self.radius(lanes: 3)
        let canonical = self.contained(
            home,
            bounds: self.inkBounds(kind),
            radius: referenceRadius)
        let scale = self.radius(lanes: lanes) / referenceRadius
        return CGPoint(x: canonical.x * scale, y: canonical.y * scale)
    }

    static func positions(
        for input: [Kind],
        lanes: Int,
        reservedBounds: CGRect? = nil,
        reservedRegions: [CGRect] = []) -> [Kind: CGPoint]
    {
        let scale = self.radius(lanes: lanes) / self.radius(lanes: 3)
        let reservation = reservedBounds.map {
            self.canonicalReservation(CGRect(
                x: $0.minX / scale, y: $0.minY / scale, width: $0.width / scale, height: $0.height / scale))
        }
        let regions = reservedRegions.map { CGRect(
            x: $0.minX / scale,
            y: $0.minY / scale,
            width: $0.width / scale,
            height: $0.height / scale) }
        return self.canonicalPositions(
            for: input,
            symbolScale: scale,
            reservedBounds: reservation,
            reservedRegions: regions).mapValues {
            CGPoint(x: $0.x * scale, y: $0.y * scale)
        }
    }

    /// Homes are proportional; actual 13 pt ink and padding are resolved at the current dial size.
    private static func canonicalPositions(
        for input: [Kind],
        symbolScale: CGFloat,
        reservedBounds: CGRect?,
        reservedRegions: [CGRect]) -> [Kind: CGPoint]
    {
        let kinds = Array(Set(input)).sorted()
        guard !kinds.isEmpty else { return [:] }
        let padding = self.padding / symbolScale
        let occupiedRegions = reservedRegions + (reservedBounds.map { [$0] } ?? [])
        let reservation = occupiedRegions.map { $0.insetBy(dx: -padding, dy: -padding) }
        let key = "\(symbolScale):" + self.layoutKey(kinds, reservations: reservation)
        if let cached = self.layoutCache[key] { return cached }
        if self.layoutCache.count >= 128 { self.layoutCache.removeAll(keepingCapacity: true) }
        let radius = self.radius(lanes: 3)
        let transform = CGAffineTransform(scaleX: 1 / symbolScale, y: 1 / symbolScale)
        let bounds = kinds.map { self.inkBounds($0).applying(transform) }
        let homes = kinds.map { self.preferred($0, lanes: 3) }
        if symbolScale == 1, reservation.isEmpty, kinds.count == Kind.allCases.count {
            // The complete catalogue is deliberately denser than ordinary warning sets. Its actual glyph ink
            // needs a few local interlocking clearances that rectangular body packing cannot discover.
            let result = Dictionary(uniqueKeysWithValues: zip(kinds, homes).map { kind, home in
                let correction = NativeOrbitWarningBulbPositions.bulbCheckCorrections[kind.catalogueKey] ?? .zero
                return (kind, CGPoint(x: home.x + correction.x, y: home.y + correction.y))
            })
            self.layoutCache[key] = result
            return result
        }
        if kinds.count == Kind.allCases.count,
           let prepared = NativeOrbitWarningCatalogueLayouts.positions(
               for: key, bounds: bounds, symbolScale: symbolScale)
        {
            // The first bulb check must not run the exhaustive packing solver on the presentation thread.
            let result = Dictionary(uniqueKeysWithValues: zip(kinds, prepared))
            self.layoutCache[key] = result
            return result
        }
        let circleArea = CGFloat.pi * radius * radius
        let reservedArea = reservation.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
        let availableArea = max(circleArea * 0.2, circleArea - reservedArea)
        let footprint = bounds.reduce(CGFloat.zero) { $0 + ($1.width + padding) * ($1.height + padding) }
        let dense = footprint > availableArea * 0.85
        // In an exhausted bulb check, distribute the unavoidable overlap evenly instead of sharing slots.
        let pitch = min(7.5, sqrt(availableArea / (CGFloat(kinds.count) * 0.866)) * 0.82)
        let hasCrowding = kinds.indices.contains { a in
            !self.avoidsReservation(homes[a], bounds: bounds[a], reservation: reservation) ||
                kinds.indices.contains { b in
                    guard a < b else { return false }
                    return bounds[a].offsetBy(dx: homes[a].x, dy: homes[a].y)
                        .insetBy(dx: -padding, dy: -padding)
                        .intersects(bounds[b].offsetBy(dx: homes[b].x, dy: homes[b].y))
                }
        }
        if !hasCrowding {
            let result = Dictionary(uniqueKeysWithValues: zip(kinds, homes))
            self.layoutCache[key] = result
            return result
        }
        var effectiveReservations = Array(repeating: reservation, count: kinds.count)
        let clearHomes = homes.enumerated().map { index, home in
            let padded = self.nearestClearPosition(
                home,
                bounds: bounds[index],
                radius: radius,
                reservation: reservation)
            if self.reservationOverlap(padded, bounds: bounds[index], reservations: reservation) > 0.00001 {
                // Yield impossible padding before sacrificing a fixed mark's actual frame.
                effectiveReservations[index] = occupiedRegions
                return self.nearestClearPosition(
                    home, bounds: bounds[index], radius: radius, reservation: occupiedRegions)
            }
            return padded
        }
        let minimumOverlap = clearHomes.enumerated().map { index, point in
            self.reservationOverlap(point, bounds: bounds[index], reservations: effectiveReservations[index])
        }
        func fitsReservation(_ point: CGPoint, index: Int) -> Bool {
            self.reservationOverlap(
                point, bounds: bounds[index], reservations: effectiveReservations[index]) <= minimumOverlap[index] +
                0.00001
        }
        func isLocal(_ point: CGPoint, index: Int) -> Bool {
            let home = homes[index]
            let necessary = hypot(clearHomes[index].x - home.x, clearHomes[index].y - home.y)
            let local: CGFloat = 13
            let allowance = necessary > 0 ? max(local, hypot(bounds[index].width, bounds[index].height)) : local
            guard hypot(point.x - home.x, point.y - home.y) <= necessary + allowance else { return false }
            if !reservation.isEmpty {
                // A centred amount can require a vertical detour, but left/right category order stays intact.
                return abs(home.x) <= radius * 0.2 || point.x * home.x >= 0
            }
            return self.inCategoryNeighbourhood(point, category: kinds[index].category, radius: radius)
        }
        let step: CGFloat = dense && !reservation.isEmpty ? 1.5 : 3
        let candidates = self.candidatePoints(bounds: bounds, radius: radius, step: step) { index, point in
            fitsReservation(point, index: index) && isLocal(point, index: index)
        }
        let problem = PackingProblem(
            homes: homes,
            bounds: bounds,
            candidates: candidates,
            clearHomes: clearHomes,
            radius: radius,
            symbolScale: symbolScale,
            pitch: pitch,
            allowed: { fitsReservation($1, index: $0) && isLocal($1, index: $0) })
        let inkArea = bounds.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
        let clearlyOverfull = inkArea > circleArea
        var best = problem.solve(relaxed: clearlyOverfull, gap: padding)
        var overlap = self.bodyOverlap(best, bounds: bounds)
        if !clearlyOverfull, overlap > 0.00001, kinds.count > 18 {
            // Preserve glyph clearance before spending the last fraction of neighbour padding.
            for fraction: CGFloat in [0.5, 0] {
                let candidate = problem.solve(relaxed: false, gap: padding * fraction)
                let candidateOverlap = self.bodyOverlap(candidate, bounds: bounds)
                if candidateOverlap < overlap { best = candidate; overlap = candidateOverlap }
                if overlap <= 0.00001 { break }
            }
        }
        if !clearlyOverfull, dense, overlap > inkArea * 0.1 { best = problem.solve(relaxed: true, gap: padding) }
        if !dense, kinds.count > 18, self.bodyOverlap(best, bounds: bounds) < 0.00001 {
            let paddedBounds = bounds.map { $0.insetBy(dx: -padding / 2, dy: -padding / 2) }
            let spaced = self.separate(start: best, bounds: paddedBounds) { index, point in
                self.isInside(point, bounds: bounds[index], radius: radius)
                    && fitsReservation(point, index: index) && isLocal(point, index: index)
            }
            if self.bodyOverlap(spaced, bounds: bounds) < 0.00001 { best = spaced }
        }
        if dense, symbolScale == 1, reservation.isEmpty {
            let original = Dictionary(uniqueKeysWithValues: zip(kinds, homes))
            let proposed = Dictionary(uniqueKeysWithValues: zip(kinds, best))
            // The evenly spaced home map also interlocks actual ink. Body boxes cannot model that detail.
            if NativeOrbitWarningInk.visibility(proposed).values.min() ?? 1
                < NativeOrbitWarningInk.visibility(original).values.min() ?? 1
            { best = homes }
        }
        let result = Dictionary(uniqueKeysWithValues: zip(kinds, best))
        self.layoutCache[key] = result
        return result
    }

    @MainActor private struct PackingObjective {
        let value: ([CGPoint]) -> CGFloat
        let moveValue: (Int, CGPoint, [CGPoint]) -> CGFloat
    }

    private static func nearestDistances(_ points: [CGPoint], excluding: Int? = nil) -> [CGFloat] {
        points.indices.map { i in
            points.indices.filter { $0 != i && $0 != excluding }.map {
                hypot(points[i].x - points[$0].x, points[i].y - points[$0].y)
            }.min() ?? .infinity
        }
    }

    @MainActor private struct PackingProblem {
        let homes: [CGPoint]
        let bounds: [CGRect]
        let candidates: [[CGPoint]]
        let clearHomes: [CGPoint]
        let radius: CGFloat
        let symbolScale: CGFloat
        let pitch: CGFloat
        let allowed: (Int, CGPoint) -> Bool

        func solve(relaxed: Bool, gap: CGFloat) -> [CGPoint] {
            func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
            func collision(_ a: Int, _ p: CGPoint, _ b: Int, _ q: CGPoint) -> CGFloat {
                let ra = self.bounds[a].offsetBy(dx: p.x, dy: p.y), rb = self.bounds[b].offsetBy(dx: q.x, dy: q.y)
                let touching = area(ra.intersection(rb))
                let crowded = (area(ra.insetBy(dx: -gap, dy: -gap).intersection(rb))
                    + area(rb.insetBy(dx: -gap, dy: -gap).intersection(ra))) / 2
                let d = hypot(p.x - q.x, p.y - q.y)
                if relaxed {
                    let nearShared = max(0, pitch * 0.66 - d)
                    return nearShared * nearShared * 500_000
                        + pow(max(0, self.pitch - d), 2) * 5000 + touching * 0.5 + crowded * 0.1
                }
                return touching * 2_000_000 + crowded * 20000 + max(0, 2 - d) * 100_000
            }
            func anchorScore(_ i: Int, _ point: CGPoint) -> CGFloat {
                let dx = point.x - self.homes[i].x, dy = point.y - self.homes[i].y
                var result = dx * dx + dy * dy
                // A light may move inward to make room, but a whole category must not migrate across the dial.
                let homeLength = max(1, hypot(homes[i].x, self.homes[i].y))
                let projection = (point.x * self.homes[i].x + point.y * self.homes[i].y) / homeLength
                result += pow(max(0, -projection), 2) * 20
                return result
            }
            var excludedIndex = -1
            var excludedPoints: [CGPoint] = []
            var excludedNearest: [CGFloat] = []
            func score(_ i: Int, _ point: CGPoint, _ current: [CGPoint]) -> CGFloat {
                guard self.allowed(i, point) else { return .infinity }
                var result = anchorScore(i, point)
                var nearest = CGFloat.infinity
                for j in self.homes.indices where j != i {
                    result += collision(i, point, j, current[j])
                    nearest = min(nearest, hypot(point.x - current[j].x, point.y - current[j].y))
                }
                if relaxed {
                    if excludedIndex != i || excludedPoints != current {
                        excludedIndex = i
                        excludedPoints = current
                        excludedNearest = NativeOrbitWarningLayout.nearestDistances(current, excluding: i)
                    }
                    result += pow(nearest - self.pitch * 0.8, 2) * 2500
                    for j in self.homes.indices where j != i {
                        let distance = min(excludedNearest[j], hypot(point.x - current[j].x, point.y - current[j].y))
                        result += pow(distance - self.pitch * 0.8, 2) * 2500
                    }
                }
                return result
            }
            let objective = PackingObjective(value: { points in
                var result: CGFloat = 0
                for i in points.indices {
                    guard self.allowed(i, points[i]) else { return .infinity }
                    result += anchorScore(i, points[i])
                    for j in points.indices where j > i {
                        result += collision(i, points[i], j, points[j])
                    }
                }
                if relaxed {
                    result += NativeOrbitWarningLayout.nearestDistances(points).reduce(0) {
                        $0 + pow($1 - self.pitch * 0.8, 2) * 2500
                    }
                }
                return result
            }, moveValue: score)
            let options: (Int, CGPoint, [CGPoint]) -> [CGPoint] = { i, current, points in
                var options = self.candidates[i] + [self.homes[i], self.clearHomes[i]]
                options += NativeOrbitWarningLayout.edgeClearances(i, points: points, bounds: self.bounds, gap: gap)
                    .filter {
                        NativeOrbitWarningLayout.isInside($0, bounds: self.bounds[i], radius: self.radius) && self
                            .allowed(
                                i,
                                $0)
                    }
                let step = 0.5 / self.symbolScale, reach = Int(floor(2 / step))
                for y in -reach...reach {
                    for x in -reach...reach {
                        let p = CGPoint(x: current.x + CGFloat(x) * step, y: current.y + CGFloat(y) * step)
                        if NativeOrbitWarningLayout.isInside(p, bounds: self.bounds[i], radius: self.radius),
                           self.allowed(
                               i,
                               p)
                        {
                            options.append(p)
                        }
                    }
                }
                return options
            }
            var settled = NativeOrbitWarningLayout.settle(
                start: self.clearHomes,
                areas: self.bounds.map { $0.width * $0.height },
                iterations: relaxed ? 16 : 12,
                objective: objective,
                options: options)
            guard !relaxed, gap == 0, self.homes.count > 18,
                  NativeOrbitWarningLayout.bodyOverlap(settled, bounds: self.bounds) > 0.00001
            else { return settled }
            settled = NativeOrbitWarningLayout.separate(
                start: settled,
                bounds: self.bounds,
                valid: { NativeOrbitWarningLayout.isInside($1, bounds: self.bounds[$0], radius: self.radius)
                    && self.allowed($0, $1)
                })
            if NativeOrbitWarningLayout.bodyOverlap(settled, bounds: self.bounds) < 0.00001 { return settled }
            let polished = NativeOrbitWarningLayout.polish(
                start: settled,
                objective: objective,
                valid: { NativeOrbitWarningLayout.isInside($1, bounds: self.bounds[$0], radius: self.radius)
                    && self.allowed($0, $1)
                },
                proposal: { i, current, value in
                    let p: CGPoint
                    if value & 1 == 0, !self.candidates[i].isEmpty {
                        p = self.candidates[i][Int((value >> 1) % UInt64(self.candidates[i].count))]
                    } else {
                        let step = 0.5 / self.symbolScale
                        p = CGPoint(
                            x: current.x + CGFloat(Int((value >> 8) & 15) - 7) * step,
                            y: current.y + CGFloat(Int((value >> 16) & 15) - 7) * step)
                    }
                    return NativeOrbitWarningLayout.isInside(p, bounds: self.bounds[i], radius: self.radius) && self
                        .allowed(
                            i,
                            p) ? p : nil
                })
            let final = NativeOrbitWarningLayout.settle(
                start: polished,
                areas: self.bounds.map { $0.width * $0.height },
                iterations: 12,
                objective: objective,
                options: options)
            return NativeOrbitWarningLayout.separate(
                start: final,
                bounds: self.bounds,
                valid: { NativeOrbitWarningLayout.isInside($1, bounds: self.bounds[$0], radius: self.radius)
                    && self.allowed($0, $1)
                })
        }
    }

    private static func candidatePoints(
        bounds: [CGRect],
        radius: CGFloat,
        step: CGFloat,
        allowed: (Int, CGPoint) -> Bool) -> [[CGPoint]]
    {
        bounds.enumerated().map { index, bounds in
            stride(from: -radius, through: radius, by: step).flatMap { y in
                stride(from: -radius, through: radius, by: step).compactMap { x -> CGPoint? in
                    let point = CGPoint(x: (x * 2).rounded() / 2, y: (y * 2).rounded() / 2)
                    return self.isInside(point, bounds: bounds, radius: radius) && allowed(index, point) ? point : nil
                }
            }
        }
    }

    /// Exact edge candidates avoid quantisation traps when the final gap is smaller than the search grid.
    private static func edgeClearances(
        _ index: Int, points: [CGPoint], bounds: [CGRect], gap: CGFloat) -> [CGPoint]
    {
        let own = bounds[index], point = points[index]
        let current = own.offsetBy(dx: point.x, dy: point.y).insetBy(dx: -gap - 0.5, dy: -gap - 0.5)
        var candidates: [CGPoint] = []
        for other in points.indices where other != index {
            let obstacle = bounds[other].offsetBy(dx: points[other].x, dy: points[other].y)
            guard current.intersects(obstacle) else { continue }
            candidates += [
                CGPoint(x: obstacle.minX - own.maxX - gap - 0.001, y: point.y),
                CGPoint(x: obstacle.maxX - own.minX + gap + 0.001, y: point.y),
                CGPoint(x: point.x, y: obstacle.minY - own.maxY - gap - 0.001),
                CGPoint(x: point.x, y: obstacle.maxY - own.minY + gap + 0.001),
            ]
        }
        return candidates
    }

    private static func bodyOverlap(_ points: [CGPoint], bounds: [CGRect]) -> CGFloat {
        points.indices.reduce(CGFloat.zero) { sum, a in
            sum + points.indices.filter { $0 > a }.reduce(CGFloat.zero) { partial, b in
                let overlap = bounds[a].offsetBy(dx: points[a].x, dy: points[a].y)
                    .intersection(bounds[b].offsetBy(dx: points[b].x, dy: points[b].y))
                return partial + (overlap.isNull ? 0 : overlap.width * overlap.height)
            }
        }
    }

    /// Try stable insertion orders without coupling the optimiser to glyph or category policy.
    private static func settle(
        start: [CGPoint],
        areas: [CGFloat],
        iterations: Int,
        objective: PackingObjective,
        options: (Int, CGPoint, [CGPoint]) -> [CGPoint]) -> [CGPoint]
    {
        var best = start, bestScore = objective.value(start)
        for seed in 0..<3 {
            var points = start
            let order = start.indices.sorted { a, b in
                if seed == 0 { return a < b }
                return areas[a] == areas[b] ? a < b : (seed == 1 ? areas[a] > areas[b] : areas[a] < areas[b])
            }
            for _ in 0..<iterations {
                var moved = false
                for i in order {
                    var choice = points[i], low = objective.moveValue(i, choice, points)
                    for candidate in options(i, points[i], points) {
                        let value = objective.moveValue(i, candidate, points)
                        if value < low - 0.001 { low = value; choice = candidate }
                    }
                    if choice != points[i] {
                        moved = true
                        points[i] = choice
                    }
                }
                if !moved { break }
            }
            let energy = objective.value(points)
            if energy < bestScore { best = points; bestScore = energy }
        }
        return best
    }

    /// Propagate a minimal separating move through neighbouring lamps instead of trapping a single lamp.
    private static func separate(
        start: [CGPoint], bounds: [CGRect], valid: (Int, CGPoint) -> Bool) -> [CGPoint]
    {
        var points = start, best = start, bestOverlap = self.bodyOverlap(start, bounds: bounds)
        for iteration in 0..<200 {
            let order = iteration.isMultiple(of: 2) ? Array(points.indices) : Array(points.indices.reversed())
            for (offset, a) in order.enumerated() {
                for b in order.dropFirst(offset + 1) {
                    let ra = bounds[a].offsetBy(dx: points[a].x, dy: points[a].y)
                    let rb = bounds[b].offsetBy(dx: points[b].x, dy: points[b].y)
                    guard ra.intersects(rb) else { continue }
                    let shifts = [
                        CGPoint(x: rb.minX - ra.maxX - 0.001, y: 0),
                        CGPoint(x: rb.maxX - ra.minX + 0.001, y: 0),
                        CGPoint(x: 0, y: rb.minY - ra.maxY - 0.001),
                        CGPoint(x: 0, y: rb.maxY - ra.minY + 0.001),
                    ]
                    var choice: (CGPoint, CGPoint)?, cost = CGFloat.infinity
                    for shift in shifts {
                        for fraction: CGFloat in [0.5, 0.25, 0.75, 0, 1] {
                            let p = CGPoint(x: points[a].x + shift.x * fraction, y: points[a].y + shift.y * fraction)
                            let q = CGPoint(
                                x: points[b].x - shift.x * (1 - fraction),
                                y: points[b].y - shift.y * (1 - fraction))
                            guard valid(a, p), valid(b, q) else { continue }
                            let movement = (shift.x * shift.x + shift.y * shift.y)
                                * (fraction * fraction + (1 - fraction) * (1 - fraction))
                            if movement < cost { cost = movement; choice = (p, q) }
                        }
                    }
                    if let choice { points[a] = choice.0; points[b] = choice.1 }
                }
            }
            let overlap = self.bodyOverlap(points, bounds: bounds)
            if overlap < bestOverlap { best = points; bestOverlap = overlap }
            if bestOverlap < 0.00001 { return best }
        }
        return best
    }

    /// Escape tightly packed local minima before concluding that glyph overlap is necessary.
    private static func polish(
        start: [CGPoint],
        objective: PackingObjective,
        valid: (Int, CGPoint) -> Bool,
        proposal: (Int, CGPoint, UInt64) -> CGPoint?) -> [CGPoint]
    {
        var state: UInt64 = 0x5113_2026
        func random() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        var points = start, best = start, bestScore = objective.value(start)
        var currentEnergy = bestScore
        for step in 0..<80000 {
            let i = Int(random() % UInt64(points.count))
            let temperature = 20_000_000 * pow(0.000001, CGFloat(step) / 80000)
            if step % 4 == 0 {
                let j = Int(random() % UInt64(points.count))
                guard i != j, valid(i, points[j]), valid(j, points[i]) else { continue }
                let old = currentEnergy
                points.swapAt(i, j)
                let energy = objective.value(points)
                let probability = CGFloat(random() >> 11) / CGFloat(UInt64.max >> 11)
                if energy <= old || probability < exp((old - energy) / (temperature * 2)) {
                    currentEnergy = energy
                    if energy < bestScore { bestScore = energy; best = points }
                } else {
                    points.swapAt(i, j)
                }
                continue
            }
            guard let candidate = proposal(i, points[i], random()) else { continue }
            let delta = objective.moveValue(i, candidate, points) - objective.moveValue(i, points[i], points)
            let probability = CGFloat(random() >> 11) / CGFloat(UInt64.max >> 11)
            if delta <= 0 || probability < exp(-delta / (temperature * 2)) {
                points[i] = candidate
                currentEnergy += delta
                if currentEnergy < bestScore { bestScore = currentEnergy; best = points }
            }
        }
        if objective.value(points) < bestScore { best = points }
        return best
    }

    /// All current budget money frames fit this one proportional envelope. Wallets use the wider envelope.
    private static func canonicalReservation(_ rect: CGRect) -> CGRect {
        let size = if rect.width <= 70.1, rect.height <= 28.1 {
            CGSize(width: 70, height: 28)
        } else if rect.width <= 92.1, rect.height <= 28.1 {
            CGSize(width: 92, height: 28)
        } else {
            CGSize(width: ceil(rect.width / 4) * 4, height: ceil(rect.height / 4) * 4)
        }
        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height)
    }

    /// Find the shortest clearing move before neighbour padding, leaving every already clear home untouched.
    private static func nearestClearPosition(
        _ home: CGPoint, bounds: CGRect, radius: CGFloat, reservation: [CGRect]) -> CGPoint
    {
        guard !self.avoidsReservation(home, bounds: bounds, reservation: reservation) else { return home }
        var best = home, distance = CGFloat.infinity, overlap = CGFloat.infinity
        for y in stride(from: -radius, through: radius, by: 0.5) {
            for x in stride(from: -radius, through: radius, by: 0.5) {
                let p = CGPoint(x: (x * 2).rounded() / 2, y: (y * 2).rounded() / 2)
                guard self.isInside(p, bounds: bounds, radius: radius),
                      abs(home.x) <= radius * 0.2 || p.x * home.x >= 0 else { continue }
                let d = pow(p.x - home.x, 2) + pow(p.y - home.y, 2)
                let occupied = self.reservationOverlap(p, bounds: bounds, reservations: reservation)
                if occupied < overlap - 0.00001 || (abs(occupied - overlap) < 0.00001 && d < distance) {
                    overlap = occupied
                    distance = d
                    best = p
                }
            }
        }
        return best
    }

    /// Reserve only the fixed marks actually rendered at this size; padding is added once by the solver.
    static func identityReservations(lanes: Int, hasCompany: Bool, hasBadge: Bool) -> [CGRect] {
        let size = lanes == 3 ? CGSize(width: 28, height: 22) : CGSize(width: 42, height: 34)
        var regions = [CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)]
        if hasCompany {
            regions.append(CGRect(x: -7.5, y: (lanes == 3 ? -24 : -34) - 7.5, width: 15, height: 15))
        }
        if hasBadge {
            regions.append(CGRect(x: -8.5, y: (lanes == 3 ? 24 : 44) - 8.5, width: 17, height: 17))
        }
        return regions
    }

    private static func layoutKey(_ kinds: [Kind], reservations: [CGRect]) -> String {
        let reservationKey = reservations.map { "|\($0.minX),\($0.minY),\($0.width),\($0.height)" }.sorted().joined()
        return kinds.map { String($0.rawValue) }.joined(separator: ",") + reservationKey
    }

    private static func avoidsReservation(_ point: CGPoint, bounds: CGRect, reservation: [CGRect]) -> Bool {
        let ink = bounds.offsetBy(dx: point.x, dy: point.y)
        return reservation.allSatisfy { !ink.intersects($0) }
    }

    /// If a wide lamp cannot clear every fixed mark, retain the least possible overlap rather than a blocked home.
    static func reservationOverlap(_ point: CGPoint, bounds: CGRect, reservations: [CGRect]) -> CGFloat {
        let ink = bounds.offsetBy(dx: point.x, dy: point.y)
        return reservations.reduce(0) { sum, region in
            let intersection = ink.intersection(region)
            return sum + (intersection.isNull ? 0 : intersection.width * intersection.height)
        }
    }

    /// Dashboard neighbourhoods: service at the top, fuel at the gauge's empty end,
    /// performance on the right, keys/accounts below, and local controls at the lower right.
    static func inCategoryNeighbourhood(_ point: CGPoint, category: String, radius: CGFloat) -> Bool {
        let x = point.x / radius, y = point.y / radius
        switch category {
        case "service": return y < -0.25
        case "billing": return x < -0.20 && y < -0.20
        case "connection": return x > 0.25 && y < -0.10
        case "pace": return x > 0.15 && y > -0.35 && y < 0.40
        case "resets": return x < -0.25 && y < 0.18
        case "reading": return x < 0.20 && y > -0.40 && y < 0.30
        case "limits": return x < -0.28 && y > 0.05
        case "accounts": return x < 0.10 && y > 0.10
        case "access": return x > -0.45 && x < 0.42 && y > 0.15
        case "codexbar": return x > -0.12 && y > 0.10
        default: return true
        }
    }

    private static func isInside(_ point: CGPoint, bounds: CGRect, radius: CGFloat) -> Bool {
        let r = bounds.offsetBy(dx: point.x, dy: point.y)
        return max(
            hypot(r.minX, r.minY),
            hypot(r.maxX, r.minY),
            hypot(r.minX, r.maxY),
            hypot(r.maxX, r.maxY)) < radius - 0.65
    }

    private static func contained(_ point: CGPoint, bounds: CGRect, radius: CGFloat) -> CGPoint {
        if self.isInside(point, bounds: bounds, radius: radius) { return point }
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<24 {
            let t = (lo + hi) / 2, p = CGPoint(x: point.x * t, y: point.y * t)
            if self.isInside(p, bounds: bounds, radius: radius) { lo = t } else { hi = t }
        }
        return CGPoint(x: point.x * lo, y: point.y * lo)
    }
}
