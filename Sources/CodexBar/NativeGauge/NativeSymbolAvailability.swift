import AppKit
import CodexBarCore

/// Which SF Symbols this macOS lacks, worked out once per system version.
///
/// Asking AppKit for a symbol's image is the only public test there is, and it leaves that symbol's vector artwork
/// in the system's cache for as long as the app runs. The badge vocabulary asks about more than a thousand symbols
/// at launch: tens of megabytes held for an answer that only changes with the system. So the missing names are
/// remembered for this system build and this list of symbols, and later launches ask nothing.
enum NativeSymbolAvailability {
    static let defaultsKey = "nativeSymbolAvailability.v1"

    /// The names in `symbols` that have no image on this system.
    static func missing(
        among symbols: [String],
        defaults: UserDefaults? = TestProcessSafety.isRunning ? nil : .standard,
        system: String = ProcessInfo.processInfo.operatingSystemVersionString,
        exists: (String) -> Bool = { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })
        -> Set<String>
    {
        let names = Set(symbols).sorted()
        let signature = self.signature(names)
        var records = defaults?.dictionary(forKey: self.defaultsKey) ?? [:]
        if let record = records[signature] as? [String: Any], record["system"] as? String == system,
           let missing = record["missing"] as? [String]
        {
            return Set(missing)
        }
        let missing = names.filter { !exists($0) }
        // One record for each list asked about; a list that changed replaces nothing and is simply not found.
        if records.count >= 8 { records.removeAll() }
        records[signature] = ["system": system, "missing": missing]
        defaults?.set(records, forKey: self.defaultsKey)
        return Set(missing)
    }

    /// The same for the same names in any order, on every launch (unlike `Hasher`, which is seeded per process).
    static func signature(_ sortedNames: [String]) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for name in sortedNames {
            for byte in name.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
            hash = (hash ^ 0xFF) &* 0x0000_0100_0000_01B3
        }
        return "\(sortedNames.count)-" + String(hash, radix: 16)
    }
}
