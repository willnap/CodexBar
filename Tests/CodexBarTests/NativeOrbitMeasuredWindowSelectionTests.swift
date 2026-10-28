import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct NativeOrbitMeasuredWindowSelectionTests {
    @Test(arguments: [UsageProvider.minimax, .opencodego, .zai])
    func `automatic constrained quota skips a descriptive placeholder and keeps the measured allowance`(
        provider: UsageProvider)
    {
        let actual = self.window(used: 25)
        let snapshot = UsageSnapshot(
            primary: self.window(used: 100, synthetic: true),
            secondary: actual,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        // The provider offers its windows as automatic candidates; the menu bar's shared selection never takes a
        // descriptive placeholder over a measured allowance.
        let selected = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: provider,
            snapshot: snapshot,
            supportsAverage: false,
            now: snapshot.updatedAt)
        #expect(selected == actual)
    }

    @Test
    func `constrained quota selection retains genuine zero and exhaustion but rejects descriptive slots`() {
        let unknown = self.window(used: 100, synthetic: true)
        let genuine = self.window(used: 60)
        #expect(ProviderUsagePresentation.mostConstrained(unknown, self.window(used: 25), genuine) == genuine)
        #expect(ProviderUsagePresentation.mostConstrained(unknown, nil) == nil)
        for used in [0.0, 100.0] {
            let measured = self.window(used: used)
            #expect(ProviderUsagePresentation.mostConstrained(unknown, measured) == measured)
        }
    }

    @Test
    func `requested quota lane falls through an unmeasured slot and preserves the requested measured order`() {
        let secondary = self.window(used: 25)
        let tertiary = self.window(used: 60)
        let snapshot = UsageSnapshot(
            primary: self.window(used: 100, synthetic: true),
            secondary: secondary,
            tertiary: tertiary,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(ProviderUsagePresentation
            .window(in: snapshot, following: [.primary, .secondary, .tertiary]) == secondary)
        #expect(ProviderUsagePresentation
            .window(in: snapshot, following: [.primary, .tertiary, .secondary]) == tertiary)
        #expect(ProviderUsagePresentation.window(in: snapshot, following: [.primary]) == nil)
    }

    @Test
    func `exhaustion selection requires a measured exhausted allowance and retains its ordering`() {
        let unknown = self.window(used: 100, synthetic: true)
        let actual = self.window(used: 100)
        #expect(ProviderUsagePresentation.exhausted(unknown, self.window(used: 25)) == nil)
        #expect(ProviderUsagePresentation.exhausted(unknown, actual) == actual)
        #expect(ProviderUsagePresentation.exhausted(nil, unknown) == nil)
    }

    private func window(used: Double, synthetic: Bool = false) -> RateWindow {
        RateWindow(
            usedPercent: used,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: synthetic ? "Unallocated" : "Measured allowance",
            isSyntheticPlaceholder: synthetic)
    }
}
