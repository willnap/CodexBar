import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NativeOrbitFiniteAllowanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func `Codebuff unknown or zero allocation is not an exhausted allowance`() {
        for snapshot in [
            CodebuffUsageSnapshot(
                creditsUsed: 0,
                creditsTotal: 0,
                creditsRemaining: 0,
                updatedAt: self.now),
            CodebuffUsageSnapshot(
                creditsUsed: 12,
                updatedAt: self.now),
            CodebuffUsageSnapshot(
                creditsRemaining: 12,
                updatedAt: self.now),
            CodebuffUsageSnapshot(
                creditsTotal: 100,
                weeklyLimit: 100,
                updatedAt: self.now),
        ] {
            let usage = snapshot.toUsageSnapshot()
            self.expectNoMeasuredQuota(
                usage,
                provider: .codebuff)
            #expect(usage.providerCost?.balance == snapshot.creditsRemaining)
        }
        let real = CodebuffUsageSnapshot(
            creditsUsed: 25,
            creditsTotal: 100,
            updatedAt: self.now).toUsageSnapshot()
        #expect(real.measuredRateWindows.first?.usedPercent == 25)
    }

    @Test func `Kilo zero pools and balance-only receipts are not measured quota`() {
        for snapshot in [
            self.kilo(
                total: 0,
                used: 0,
                remaining: 0),
            self.kilo(
                total: 0,
                used: 0,
                remaining: 0,
                passTotal: 0,
                passUsed: 0,
                passRemaining: 0),
            self.kilo(
                total: 12,
                used: 0,
                remaining: 12,
                unavailable: true),
        ] {
            let usage = snapshot.toUsageSnapshot()
            self.expectNoMeasuredQuota(
                usage,
                provider: .kilo)
            #expect(usage.providerCost?.balance == snapshot.creditsRemaining)
        }
        let real = self.kilo(
            total: 100,
            used: 25,
            remaining: 75).toUsageSnapshot()
        #expect(real.measuredRateWindows.first?.usedPercent == 25)
    }

    @Test func `DeepSeek balances and account availability never fabricate quota or billing causes`() {
        for amount in [0.0, 12, -1] {
            let usage = self.deepseek(
                amount,
                available: true)
            self.expectNoMeasuredQuota(
                usage,
                provider: .deepseek)
            #expect(usage.providerCost?.balance == amount)
            #expect(usage.subscriptionStatus == nil)
        }
        let unavailable = self.deepseek(
            12,
            available: false)
        self.expectNoMeasuredQuota(
            unavailable,
            provider: .deepseek)
        #expect(unavailable.subscriptionStatus == nil)
        #expect(unavailable.detailRow(label: "Status")?.value == "Unavailable")
        let metrics = NativeOrbitAccountMetrics.make(
            provider: .deepseek,
            snapshot: unavailable,
            usage: nil,
            now: self.now)
        #expect(!NativeOrbitWarningSignals.account(
            provider: .deepseek,
            snapshot: unavailable,
            metrics: metrics,
            history: [],
            now: self.now)
            .contains { $0.kind == .billing })
    }

    @Test func `Warp unlimited and zero-capacity states preserve descriptions without measured arcs`() {
        for (limit, unlimited) in [(0, false), (100, true)] {
            let usage = WarpUsageSnapshot(
                requestLimit: limit,
                requestsUsed: 0,
                nextRefreshTime: self.now.addingTimeInterval(3600),
                isUnlimited: unlimited,
                updatedAt: self.now,
                bonusCreditsRemaining: 12,
                bonusCreditsTotal: 0,
                bonusCreditsReported: true).toUsageSnapshot()
            self.expectNoMeasuredQuota(
                usage,
                provider: .warp)
            #expect(usage.providerCost?.balance == 12)
            if unlimited { #expect(usage.primary?.resetDescription == "Unlimited") }
        }
        let real = WarpUsageSnapshot(
            requestLimit: 100,
            requestsUsed: 25,
            nextRefreshTime: nil,
            isUnlimited: false,
            updatedAt: self.now).toUsageSnapshot()
        #expect(real.measuredRateWindows.first?.usedPercent == 25)
    }

    @Test func `IBM Bob missing or zero team limits preserve actual usage without full remaining capacity`() {
        for limit in [nil, 0] as [Double?] {
            let usage = self.bob(limit: limit)
            self.expectNoMeasuredQuota(
                usage,
                provider: .ibmbob)
            #expect(usage.details.first?.rows.first?.value.contains("25") == true)
        }
        #expect(self.bob(limit: 100).measuredRateWindows.first?.usedPercent == 25)
    }

    @Test func `MiniMax missing legacy percentage preserves points without manufacturing zero use`() {
        for percent in [nil, .nan, .infinity] as [Double?] {
            let usage = self.minimax(percent: percent)
            self.expectNoMeasuredQuota(
                usage,
                provider: .minimax)
            #expect(usage.providerCost?.balance == 12)
        }
        for percent in [0.0, 25, 100] {
            #expect(self.minimax(percent: percent).measuredRateWindows.first?.usedPercent == percent)
        }
        let unlimited = MiniMaxServiceUsage(
            serviceType: "general",
            windowType: "5 hours",
            timeRange: "Fixture",
            usage: 0,
            limit: 0,
            percent: 0,
            isUnlimited: true,
            resetsAt: nil,
            resetDescription: "Unlimited")
        self.expectNoMeasuredQuota(self.minimax(percent: nil, services: [unlimited]), provider: .minimax)
    }

    private func expectNoMeasuredQuota(
        _ usage: UsageSnapshot,
        provider: UsageProvider)
    {
        #expect(usage.measuredRateWindows.isEmpty)
        let state = NativeUsageGaugeProjection.state(
            provider: provider,
            snapshot: usage)
        #expect((state.windows ?? []).allSatisfy { $0.usedFraction == nil })
        let metrics = NativeOrbitAccountMetrics.make(
            provider: provider,
            snapshot: usage,
            usage: nil,
            now: self.now)
        let lights = NativeOrbitWarningSignals.account(
            provider: provider,
            snapshot: usage,
            metrics: metrics,
            history: [],
            now: self.now)
        #expect(!lights.contains { $0.kind == .limit || $0.kind == .aheadOfPace || $0.kind == .farAheadPace })
    }

    private func kilo(
        total: Double,
        used: Double,
        remaining: Double,
        unavailable: Bool = false,
        passTotal: Double? = nil,
        passUsed: Double? = nil,
        passRemaining: Double? = nil) -> KiloUsageSnapshot
    {
        KiloUsageSnapshot(
            creditsUsed: used,
            creditsTotal: total,
            creditsRemaining: remaining,
            creditsUsageIsUnavailable: unavailable,
            passUsed: passUsed,
            passTotal: passTotal,
            passRemaining: passRemaining,
            planName: nil,
            autoTopUpEnabled: nil,
            autoTopUpMethod: nil,
            updatedAt: self.now)
    }

    private func deepseek(
        _ balance: Double,
        available: Bool) -> UsageSnapshot
    {
        DeepSeekUsageSnapshot(
            isAvailable: available,
            currency: "USD",
            totalBalance: balance,
            grantedBalance: 0,
            toppedUpBalance: balance,
            updatedAt: self.now).toUsageSnapshot()
    }

    private func bob(limit: Double?) -> UsageSnapshot {
        IBMBobUsageSnapshot(
            teams: [.init(
                instanceName: "Fixture",
                teamName: "Fixture",
                planName: nil,
                usedBobcoins: 25,
                limitBobcoins: limit,
                resetsAt: nil)],
            updatedAt: self.now).toUsageSnapshot()
    }

    private func minimax(percent: Double?, services: [MiniMaxServiceUsage]? = nil) -> UsageSnapshot {
        MiniMaxUsageSnapshot(
            planName: nil,
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: percent,
            resetsAt: nil,
            updatedAt: self.now,
            services: services,
            pointsBalance: 12).toUsageSnapshot()
    }
}
