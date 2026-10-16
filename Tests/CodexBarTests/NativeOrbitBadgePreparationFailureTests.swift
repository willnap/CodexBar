import Testing
@testable import CodexBar

/// Preparation transport failures use owned data only. These injected calls never reach the SDK.
@MainActor struct NativeOrbitBadgePreparationFailureTests {
    private enum Failure: Error { case unavailable }

    @Test func `preparation error retains current owned label and honest retry error`() async {
        let account = NativeOrbitBadgeModel.Account(
            id: "filing", text: "", label: "Tax filing", alias: "old.painting")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in throw Failure.unavailable }

        #expect(result.purposes["filing"] == "Tax filing")
        #expect(result.retrievalQueries["filing"] == "Tax filing")
        #expect(result.errors["filing"] != nil)
        #expect(!result.complete && !result.cancelled)
    }

    @Test func `explicit current use cannot recover a stale alias after preparation fails`() async {
        let account = NativeOrbitBadgeModel.Account(
            id: "current", text: "", label: "Former work email, now astronomy", alias: "old.pottery")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in throw Failure.unavailable }

        #expect(result.purposes["current"] == "astronomy")
        #expect(result.retrievalQueries["current"] == "astronomy")
    }

    @Test(arguments: [
        ("Mailbox B", "gardening.club", "gardening club"),
        ("Main", "woodwork.practice", "woodwork practice"),
        ("Jordan Shaw", "ceramics.practice", "ceramics practice"),
    ])
    func `identifier personal name or generic identity can retain its owned alias`(_ input: (
        String,
        String,
        String)) async
    {
        let account = NativeOrbitBadgeModel.Account(id: "alias", text: "", label: input.0, alias: input.1)
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in throw Failure.unavailable }

        #expect(result.purposes["alias"] == input.2)
        #expect(result.retrievalQueries["alias"] == input.2)
        #expect(result.errors["alias"] != nil)
    }

    @Test(arguments: ["Gardening", "Project Aquila"])
    func `successful none for a descriptive label cannot become a fallback`(_ label: String) async {
        let account = NativeOrbitBadgeModel.Account(
            id: "none", text: "", label: label, alias: "old.photography")
        let result = await NativeOrbitBadgeModel.prepare([account]) { _ in (source: "none", terms: []) }

        #expect(result.purposes["none"]?.isEmpty == true)
        #expect(result.retrievalQueries["none"]?.isEmpty == true)
        #expect(result.errors.isEmpty && result.complete)
    }

    @Test func `one preparation error still prepares useful peers`() async {
        let accounts = [
            NativeOrbitBadgeModel.Account(id: "failed", text: "", label: "Tax filing"),
            NativeOrbitBadgeModel.Account(id: "running", text: "", label: "Running"),
        ]
        let result = await NativeOrbitBadgeModel.prepare(accounts) { account in
            if account.id == "failed" { throw Failure.unavailable }
            return (source: "label", terms: ["fitness"])
        }

        #expect(result.purposes == ["failed": "Tax filing", "running": "Running"])
        #expect(result.retrievalQueries["running"] == "Running; fitness")
        #expect(Set(result.errors.keys) == ["failed"])
    }

    @Test func `thrown cancellation stops preparation without an owned fallback`() async {
        let accounts = [
            NativeOrbitBadgeModel.Account(id: "cancelled", text: "Astronomy"),
            NativeOrbitBadgeModel.Account(id: "later", text: "Gardening"),
        ]
        var calls = 0
        let result = await NativeOrbitBadgeModel.prepare(accounts) { _ in
            calls += 1
            throw CancellationError()
        }

        #expect(result.cancelled && !result.complete)
        #expect(result.purposes.isEmpty && result.retrievalQueries.isEmpty && result.errors.isEmpty)
        #expect(calls == 1)
    }

    @Test func `noncooperative preparation success cannot override task cancellation`() async {
        let task = Task { @MainActor in
            let account = NativeOrbitBadgeModel.Account(id: "cancelled", text: "Astronomy")
            let result = await NativeOrbitBadgeModel.prepare([account]) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return (source: "label", terms: ["stars"])
            }
            #expect(result.cancelled && !result.complete)
            #expect(result.purposes.isEmpty && result.retrievalQueries.isEmpty && result.errors.isEmpty)
        }
        await task.value
    }

    @Test func `cancelled preparation never enters final classification even if the task is live`() async {
        let accounts = [
            NativeOrbitBadgeModel.Account(id: "prepared", text: "Astronomy"),
            NativeOrbitBadgeModel.Account(id: "cancelled", text: "Gardening"),
        ]
        var classified = false
        let result = await NativeOrbitBadgeModel.preparedSelection(prepare: {
            await NativeOrbitBadgeModel.prepare(accounts) { account in
                if account.id == "cancelled" { throw CancellationError() }
                return (source: "label", terms: ["stars"])
            }
        }, classify: { preparation in
            classified = true
            return preparation
        })

        #expect(result.cancelled && !Task.isCancelled)
        #expect(!classified)
    }

    @Test func `missing peer preparation cannot make a shared current subject unique`() {
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [Self.astronomyProposal],
            for: Self.accounts(peerLabel: "Now astronomy"),
            purposes: ["astronomy": "astronomy"])

        #expect(badges["astronomy"] != "star.fill")
    }

    @Test func `peer abstention cannot hide its explicit shared current subject`() {
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [Self.astronomyProposal],
            for: Self.accounts(peerLabel: "Now astronomy"),
            purposes: ["astronomy": "astronomy", "peer": ""])

        #expect(badges["astronomy"] != "star.fill")
    }

    @Test func `missing peer preparation ignores its stale alias when current subjects differ`() {
        let badges = NativeOrbitBadgeResolver.mergedBadges(
            [Self.astronomyProposal],
            for: Self.accounts(peerLabel: "Now gardening"),
            purposes: ["astronomy": "astronomy"])

        #expect(badges["astronomy"] == "star.fill")
    }

    private static let astronomyProposal = NativeOrbitBadgeModel.Proposal(
        accountID: "astronomy",
        key: "star",
        symbol: "star.fill",
        evidence: "Now astronomy",
        searchQuery: "astronomy; stars")

    private static func accounts(peerLabel: String) -> [NativeOrbitAccountPresentation] {
        [
            self.account("astronomy", label: "Now astronomy", email: "old.finance@gmail.com"),
            self.account("peer", label: peerLabel, email: "old.astronomy@gmail.com"),
        ]
    }

    private static func account(_ id: String, label: String, email: String) -> NativeOrbitAccountPresentation {
        .init(
            id: id,
            label: label,
            email: email,
            symbol: "gearshape",
            isActive: false,
            canActivate: false,
            gauge: ComputeGauge.State(),
            updatedAt: nil,
            history: [],
            odometer: nil,
            odometerHelp: nil,
            statusText: nil,
            selection: .none)
    }
}
