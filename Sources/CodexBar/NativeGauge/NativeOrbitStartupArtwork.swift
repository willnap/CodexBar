import AppKit
import CodexBarCore

/// Warm the catalogue with the same occupied regions the live account face gives its warning lamps.
@MainActor
enum NativeOrbitStartupArtwork {
    struct Geometry: Equatable {
        let lanes: Int
        let reservedBounds: CGRect?
        let reservedRegions: [CGRect]
    }

    static func prepare(
        account: NativeOrbitAccountPresentation,
        badge: String?,
        now: Date,
        screen: NSScreen?,
        realLights: [NativeOrbitWarningLight] = [],
        readiness: NativeOrbitStartupReadiness = .pending,
        appearance: NSAppearance? = nil)
    {
        let geometry = self.geometry(account: account, badge: badge, now: now)
        NativeOrbitWarningHDRView.prepare(
            lanes: geometry.lanes,
            reservedBounds: geometry.reservedBounds,
            reservedRegions: geometry.reservedRegions,
            screen: screen,
            realLights: realLights,
            readiness: readiness,
            appearance: appearance)
    }

    /// A live, uninspected dial. The legacy bulb check temporarily makes room by hiding its monetary reading.
    static func geometry(
        account: NativeOrbitAccountPresentation,
        badge: String?,
        now: Date,
        isBulbCheck: Bool = false) -> Geometry
    {
        let windows = account.gauge.resolvedWindows
        let mode = NativeOrbitMonetaryInstrument.mode(
            account: account,
            windows: windows,
            date: nil,
            now: now,
            projection: nil)
        let quotaLanes = min(3, max(1, windows.count))
        let hasCompany = UsageProduct.companyID(account.gauge.provider) != nil
        guard let mode else {
            return Geometry(
                lanes: quotaLanes,
                reservedBounds: nil,
                reservedRegions: NativeOrbitWarningLayout.identityReservations(
                    lanes: quotaLanes,
                    hasCompany: hasCompany,
                    hasBadge: badge != nil))
        }
        let moneyLanes = mode == .budgetRemaining ? min(3, windows.count) : 0
        let size = NativeOrbitMoneyReading.size(lanes: moneyLanes)
        let halfHeight = size.height / 2
        var regions = [CGRect(x: -15, y: -halfHeight - 28, width: 30, height: 22)]
        if hasCompany {
            regions.append(CGRect(x: -10, y: -halfHeight - 47, width: 20, height: 18))
        }
        if badge != nil {
            regions.append(CGRect(x: -10, y: halfHeight + 8, width: 20, height: 18))
        }
        return Geometry(
            lanes: mode == .balance || mode == .spend ? 1 : quotaLanes,
            reservedBounds: isBulbCheck ? nil : CGRect(
                x: -size.width / 2,
                y: -halfHeight,
                width: size.width,
                height: size.height),
            reservedRegions: regions)
    }
}
