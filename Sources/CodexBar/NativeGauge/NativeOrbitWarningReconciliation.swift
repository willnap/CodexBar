import Foundation

extension NativeOrbitWarningLight {
    /// A dashboard reports the most actionable interpretation of one condition, rather than opposing advice.
    /// The catalogue's bulb check deliberately uses `merged` instead.
    static func reconciled(_ lights: [Self]) -> [Self] {
        let merged = Self.merged(lights)
        let kinds = Set(merged.map(\.kind))
        let allowanceRisk = kinds.contains(.allExhausted) || kinds.contains(.limit)
        let pressure = kinds.contains(.farAheadPace) || kinds.contains(.aheadOfPace)
        let specificAccess: Set<Kind> = [.keychain, .wrongAccount, .permission, .browserSession]
        let specificFailure: Set<Kind> = [
            .outage, .overloaded, .usageFailing, .rateLimited, .apiChanged, .botCheck, .macOffline,
            .unreachable, .insecure, .signIn, .keychain, .wrongAccount, .permission, .browserSession, .helper,
        ]
        return merged.filter { light in
            switch light.kind {
            case .limit: !kinds.contains(.allExhausted)
            case .behindPace: !allowanceRisk && !pressure && !kinds.contains(.spike)
            case .aheadOfPace: !allowanceRisk && !kinds.contains(.farAheadPace)
            case .farAheadPace: !allowanceRisk
            case .idle: !allowanceRisk && !pressure && !kinds.contains(.spike) && !kinds.contains(.usedElsewhere)
            case .degraded: !kinds.contains(.outage)
            case .unreachable: !kinds.contains(.macOffline)
            case .signIn: kinds.isDisjoint(with: specificAccess)
            case .unknownError: kinds.isDisjoint(with: specificFailure)
            case .switching: light.severity != .opportunity || !kinds.contains(.allExhausted)
            default: true
            }
        }
    }
}
