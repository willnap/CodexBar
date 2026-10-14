import AppKit
import CodexBarCore
import Foundation

/// Opt-in development evidence from the same state that renders the live account popup.
@MainActor
enum NativeOrbitHistoryInspectionProof {
    private static var buildMilliseconds: [String: Double] = [:]

    static func write(provider: UsageProvider, store: UsageStore, state: NativeOrbitPopupState) {
        // A scrub audit times hover pacing, which these per-refresh dumps of every provider would dominate.
        guard CommandLine.arguments.contains("--native-popup-preview-provider"),
              ProcessInfo.processInfo.environment["CODEXBAR_PREVIEW_SCRUB"] == nil else { return }
        self.writeSnapshot(provider: provider, store: store, state: state)
        for other in UsageProvider.allCases where other != provider
            && store.settings.isProviderEnabledCached(provider: other, metadataByProvider: store.providerMetadata)
        {
            let otherState = NativeOrbitPopupState()
            let started = Date()
            otherState.accounts = store.nativeOrbitAccounts(for: other)
            self.buildMilliseconds[other.rawValue] = Date().timeIntervalSince(started) * 1000
            otherState.now = state.now
            otherState.isReady = store.nativePopupIsReady(for: other, accounts: otherState.accounts)
            self.writeSnapshot(provider: other, store: store, state: otherState)
        }
    }

    /// Rings as hovering shows them, past and ahead, from the same lanes and projection the column renders.
    private static func ringReadings(
        _ account: NativeOrbitAccountPresentation,
        state: NativeOrbitPopupState) -> [[String: Any]]
    {
        [-20.0, -19, -18.8, -6, -1, -0.2, 1, 6, 20].map { hours in
            let date = state.now.addingTimeInterval(hours * 3600)
            // The past corners exactly as the column computes them while hovering.
            let corners = date < state.now
                ? account.metrics.at(date, observedAt: account.updatedAt, history: account.history)
                .summary(days: state.days, now: date)
                : nil
            let windows = NativeOrbitHistoricalInspection.windows(
                account: account,
                date: date,
                now: state.now,
                days: state.days,
                preparedLanes: state.renderLanes(for: account),
                projection: state.projection(for: account),
                isProjecting: state.isProjecting)
            return [
                "hours": hours,
                "windows": windows.map(\.id),
                "used": windows.map { $0.used.map { ($0 * 1000).rounded() / 1000 } as Any? ?? NSNull() },
                "cost": corners?.cost as Any? ?? NSNull(),
                "tokens": corners?.tokens as Any? ?? NSNull(),
            ]
        }
    }

    /// When each input of the popup's first frames became available, relative to launch.
    private static func launchTimeline(
        provider: UsageProvider,
        store: UsageStore,
        state: NativeOrbitPopupState) -> [String: Any]
    {
        let launched = NSRunningApplication.current.launchDate ?? Date()
        return [
            "secondsSinceLaunch": Date().timeIntervalSince(launched),
            "launchDateKnown": NSRunningApplication.current.launchDate != nil,
            "popupReady": state.isReady,
            "readinessWaitRemaining": store.nativePopupReadinessWaitRemaining(),
            "historyLoaded": store.planUtilizationHistoryLoaded,
            "providerHistoryAvailable": store.nativeHistoryAvailable(provider),
            "claudeSwapRows": store.claudeSwapAccountSnapshots.count,
            "claudeSwapListTimeline": store.claudeSwapTransientState.listTimeline.map {
                "\($0.0)@\(String(format: "%.2f", $0.1.timeIntervalSince(launched)))"
            },
            "claudeSwapListedSecondsSinceLaunch": store.claudeSwapLastRefreshAt.map { $0.timeIntervalSince(launched) }
                as Any? ?? NSNull(),
        ]
    }

    private static func writeSnapshot(provider: UsageProvider, store: UsageStore, state: NativeOrbitPopupState) {
        let rows: [[String: Any]] = state.accounts.enumerated().map { index, account in
            let metrics = account.metrics
            let periods: [[String: Any]] = [1, 7, 30].map { days in
                let summary = metrics.summary(days: days, now: state.now)
                return [
                    "days": days,
                    "tokens": summary.tokens as Any? ?? NSNull(),
                    "cost": summary.cost as Any? ?? NSNull(),
                    "currency": summary.currencyCode,
                    "costEstimated": summary.costIsEstimated,
                    "costPartial": summary.costIsPartial,
                    "requests": summary.requests as Any? ?? NSNull(),
                    "partial": summary.isPartial,
                    "usageScope": summary.usageScope.rawValue,
                ]
            }
            let histories: [[String: Any]] = account.history.map { history in
                [
                    "lane": history.name.rawValue,
                    "windowMinutes": history.windowMinutes,
                    "observations": history.entries.count,
                    "firstObservedAt": history.entries.map(\.capturedAt).min()?.timeIntervalSince1970 as Any?
                        ?? NSNull(),
                    "lastObservedAt": history.entries.map(\.capturedAt).max()?.timeIntervalSince1970 as Any?
                        ?? NSNull(),
                ]
            }
            let observedDates = account.history.flatMap(\.entries).map(\.capturedAt)
            let inspectionDates = Set([observedDates.min(), observedDates.max()].compactMap(\.self))
            let historicalReadings: [[String: Any]] = inspectionDates.sorted().map { date in
                let historical = metrics.at(date, observedAt: account.updatedAt, history: account.history)
                let summary = historical.summary(days: 1, now: date)
                return [
                    "inspectedAt": date.timeIntervalSince1970,
                    "tokens": summary.tokens as Any? ?? NSNull(),
                    "cost": summary.cost as Any? ?? NSNull(),
                    "costPartial": summary.costIsPartial,
                    "balance": historical.reportedBalance?.value as Any? ?? NSNull(),
                    "bankedResets": historical.bankedResets as Any? ?? NSNull(),
                ]
            }
            // Hover evidence at 18:00 on each of the last seven local days, as every column renders it.
            let calendar = Calendar.current
            let dailyReadings: [[String: Any]] = (0..<7).compactMap { offset -> [String: Any]? in
                guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: state.now)),
                      let date = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day), date < state.now
                else { return nil }
                let started = Date()
                let historical = metrics.at(date, observedAt: account.updatedAt, history: account.history)
                let day1 = historical.summary(days: 1, now: date)
                let day7 = historical.summary(days: 7, now: date)
                return [
                    "inspectedAt": date.timeIntervalSince1970,
                    "tokens1d": day1.tokens as Any? ?? NSNull(),
                    "cost1d": day1.cost as Any? ?? NSNull(),
                    "tokens7d": day7.tokens as Any? ?? NSNull(),
                    "cost7d": day7.cost as Any? ?? NSNull(),
                    "balance": historical.reportedBalance?.value as Any? ?? NSNull(),
                    "bankedResets": historical.bankedResets as Any? ?? NSNull(),
                    "extraFraction": historical.extraUsageFraction as Any? ?? NSNull(),
                    "milliseconds": Date().timeIntervalSince(started) * 1000,
                ]
            }
            // Typed resets over the last 30 days, classified exactly as the chart draws them.
            let resetEvents: [[String: Any]] = NativeOrbitHistoryWidget.resetEvents(NativeOrbitHistoryWidget(
                histories: account.history,
                now: state.now,
                days: 30,
                provider: provider,
                peerHistories: state.accounts.filter { $0.id != account.id }.map(\.history)).lanes)
                .map { event in
                    [
                        "kind": event.kind.rawValue,
                        "at": event.date.timeIntervalSince1970,
                        "earliest": event.earliest?.timeIntervalSince1970 as Any? ?? NSNull(),
                        "lanes": event.laneIDs,
                        "quantity": event.quantity,
                    ]
                }
            return [
                "ringReadings": Self.ringReadings(account, state: state),
                "liveWindows": account.gauge.resolvedWindows.map(\.id),
                "lanes": state.renderLanes(for: account).map(\.history.name.rawValue),
                "resetEvents": resetEvents,
                "resetCorner": String(
                    describing: NativeOrbitResetCornerState.resolve(provider: provider, metrics: metrics)),
                "extraUsageIcon": String(describing: NativeOrbitInstruments.extraUsageIcon(
                    metrics,
                    creditUsage: metrics.recordedCreditUsage(days: 1, now: state.now),
                    moment: account.updatedAt == nil ? .loading : .live,
                    history: account.history)),
                "dailyReadings": dailyReadings,
                "accountIndex": index,
                "active": account.isActive,
                // A remembered reading stands in for this column's local usage until the live one publishes.
                "usageLastKnownAt": account.usageLastKnownAt?.timeIntervalSince1970 as Any? ?? NSNull(),
                // The store's warning lights with their reasons (the popup adds fuel and steering itself).
                "warningLights": account.warnings.map { "\($0.kind)/\($0.severity): \($0.detail)" },
                "updatedAt": account.updatedAt?.timeIntervalSince1970 as Any? ?? NSNull(),
                "dailyTokenBuckets": metrics.usage?.daily.count ?? 0,
                "datedUsageEvents": metrics.usage?.quotaSlices.count ?? 0,
                "localCostReport": metrics.localCostUsage != nil,
                "billingSpend": metrics.reportedSpend != nil,
                "billingSpendValue": metrics.reportedSpend?.used as Any? ?? NSNull(),
                "billingSpendLimit": metrics.reportedSpend?.limit as Any? ?? NSNull(),
                "billingSpendCurrency": metrics.reportedSpend?.currencyCode as Any? ?? NSNull(),
                "usedResets": metrics.usedResets,
                "localDailyTokenBuckets": metrics.localCostUsage?.snapshot.daily.count ?? 0,
                "localDatedUsageEvents": metrics.localCostUsage?.snapshot.quotaSlices.count ?? 0,
                "balance": metrics.reportedBalance != nil,
                "balanceValue": metrics.reportedBalance?.value as Any? ?? NSNull(),
                "balanceUnit": metrics.reportedBalance?.unit as Any? ?? NSNull(),
                "providerPeriodTokens": metrics.providerPeriodTokenReading(now: state.now)?.tokens as Any?
                    ?? NSNull(),
                "providerPeriodSpend": metrics.providerPeriodSpendReading(now: state.now)?.cost as Any?
                    ?? NSNull(),
                "bankedResets": metrics.bankedResets as Any? ?? NSNull(),
                "periods": periods,
                "histories": histories,
                "historicalReadings": historicalReadings,
            ]
        }
        var proof: [String: Any] = [
            "provider": provider.rawValue,
            "capturedAt": state.now.timeIntervalSince1970,
            "costUsageEnabled": store.settings.isCostUsageEffectivelyEnabled(for: provider),
            "ambientSnapshot": store.snapshot(for: provider.instanceID) != nil,
            // Provider-specific by design: Claude transcripts are a machine source, separate from its named accounts.
            "localMachineReport": provider == .claude ? store.nativeOrbitClaudeLocalUsage() != nil : false,
            "dashboardSources": store.spendDashboardPublication.sources.map {
                ["provider": $0.provider?.rawValue ?? "unknown", "state": String(describing: $0.state)]
            },
            "accounts": rows,
            // Provider-specific by design: only Codex splits shared local sessions between accounts.
            "codexAttribution": provider == .codex ? store.nativeCodexSessionAttribution.diagnostics : [:],
            "accountsBuildMilliseconds": self.buildMilliseconds[provider.rawValue] as Any? ?? NSNull(),
            "lastKnownRestoredAt": store.nativeLastKnownUsage.restoredAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "lastKnownRestoredEntries": store.nativeLastKnownUsage.restoredCounts[provider] as Any? ?? NSNull(),
            // Provider-specific by design: the app's own Claude OAuth read is the ambient reset-inventory source.
            "ambientClaudeResets": provider == .claude
                ? (store.snapshots[.claude]?.claudeResetCredits.map { credits -> [String: Any] in
                    [
                        "available": credits.availableExpirations(at: state.now).count,
                        "used": credits.usedExpirations.count,
                    ]
                } as Any? ?? NSNull()) : NSNull(),
        ]
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-native-history-\(provider.rawValue).json")
        proof.merge(Self.launchTimeline(provider: provider, store: store, state: state)) { current, _ in current }
        guard let data = try? JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: path, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
