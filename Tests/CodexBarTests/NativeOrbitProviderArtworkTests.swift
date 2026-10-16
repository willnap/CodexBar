import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NativeOrbitProviderArtworkTests {
    @Test func `existing popup artwork retain their artwork`() {
        #expect(NativeOrbitProviderArtwork.name(for: "codex", assetExists: { $0 == "provider.codex" })
            == "provider.codex")
        #expect(NativeOrbitProviderArtwork.name(for: "claude", assetExists: { $0 == "provider.claudecode" })
            == "provider.claudecode")
        #expect(NativeOrbitProviderArtwork.name(for: "anthropic", assetExists: { $0 == "provider.claude" })
            == "provider.claude")
    }

    @Test(arguments: ["copilot", "cursor", "openrouter", "deepseek", "elevenlabs"])
    func `providers without popup artwork use their actual native asset`(_ product: String) {
        #expect(NativeOrbitProviderArtwork.name(for: product, assetExists: { _ in false })
            == "provider.\(product).compact.p22")
    }

    @Test func `every registered service resolves to an asset in the shared catalogue`() {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        let catalogue = root.appendingPathComponent("Implementation/Components/UsageIndicator/ComputeGauge.xcassets")
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: catalogue.appendingPathComponent(name + ".symbolset").path)
        }
        for service in ServiceIdentity.all {
            let name = NativeOrbitProviderArtwork.name(for: service.product, assetExists: exists)
            #expect(exists(name), "Missing provider artwork: \(service.product) → \(name)")
        }
    }
}
