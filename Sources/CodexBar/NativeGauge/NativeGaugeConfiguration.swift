import CodexBarCore
import Foundation

enum NativeGaugeConfiguration {
    static var isEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CodexBarNativeGauges") as? Bool == true
    }
}
