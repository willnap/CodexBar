/// Offline fixture generator; compile through generate_warning_catalogue_layouts.py.
@main struct Generate {
    @MainActor static func main() throws {
        typealias Kind = NativeOrbitWarningLight.Kind
        var layouts: [String: [[Double]]] = [:]
        func capture(_ name: String, lanes: Int, reserved: CGRect?, regions: [CGRect]) {
            let begin = CFAbsoluteTimeGetCurrent()
            let positions = NativeOrbitWarningLayout.positions(
                for: Kind.allCases,
                lanes: lanes,
                reservedBounds: reserved,
                reservedRegions: regions)
            let scale = NativeOrbitWarningLayout.radius(lanes: lanes) / NativeOrbitWarningLayout.radius(lanes: 3)
            let normalized = regions.map { CGRect(
                x: $0.minX / scale,
                y: $0.minY / scale,
                width: $0.width / scale,
                height: $0.height / scale) }
            let center = reserved.map { NativeOrbitWarningLayout.canonicalReservation(CGRect(
                x: $0.minX / scale,
                y: $0.minY / scale,
                width: $0.width / scale,
                height: $0.height / scale)) }
            let padding = NativeOrbitWarningLayout.padding / scale
            let reservations = (normalized + (center.map { [$0] } ?? [])).map { $0.insetBy(dx: -padding, dy: -padding) }
            let key = "\(scale):" + NativeOrbitWarningLayout.layoutKey(Kind.allCases, reservations: reservations)
            layouts[key] = Kind.allCases.map { let point = positions[$0]!; return [
                Double(point.x / scale),
                Double(point.y / scale),
            ] }
            print(name, "seconds", CFAbsoluteTimeGetCurrent() - begin)
            fflush(stdout)
        }
        for lanes in 1...3 {
            for company in [false, true] {
                for badge in [false, true] {
                    capture(
                        "identity-\(lanes)-\(company)-\(badge)",
                        lanes: lanes,
                        reserved: nil,
                        regions: NativeOrbitWarningLayout.identityReservations(
                            lanes: lanes,
                            hasCompany: company,
                            hasBadge: badge))
                }
            }
        }
        for moneyLanes in 0...3 {
            for company in [false, true] {
                for badge in [false, true] {
                    let size = NativeOrbitMoneyReading.size(lanes: moneyLanes)
                    let height = size.height, width = size.width
                    let halfHeight = height / 2
                    var regions = [CGRect(x: -15, y: -halfHeight - 28, width: 30, height: 22)]
                    if company { regions.append(CGRect(x: -10, y: -halfHeight - 47, width: 20, height: 18)) }
                    if badge { regions.append(CGRect(x: -10, y: halfHeight + 8, width: 20, height: 18)) }
                    capture(
                        "money-\(moneyLanes)-\(company)-\(badge)",
                        lanes: max(1, moneyLanes),
                        reserved: CGRect(x: -width / 2, y: -halfHeight, width: width, height: height),
                        regions: regions)
                    capture(
                        "bulbs-money-\(moneyLanes)-\(company)-\(badge)",
                        lanes: max(1, moneyLanes),
                        reserved: nil,
                        regions: regions)
                }
            }
        }
        let bounds = Kind.allCases.map { k in let b = NativeOrbitWarningLayout.inkBounds(k); return [
            Double(b.minX),
            Double(b.minY),
            Double(b.width),
            Double(b.height),
        ] }
        let data = try JSONSerialization.data(
            withJSONObject: ["bounds": bounds, "layouts": layouts],
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("TOTAL", layouts.count)
    }
}
