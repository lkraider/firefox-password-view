import Testing
@testable import Keywise

@MainActor
struct AppModelTests {
    /// The chrome://FirefoxAccounts password is Mozilla Account sync key
    /// material. The first activation asks for confirmation and shows
    /// nothing.
    @Test func theAccountRowNeedsASecondActivation() async {
        let model = await openSyncShaped()
        guard let row = model.entries.firstIndex(where: { $0.isAccountCredential }) else {
            Issue.record("sync-shaped carries no account credential row")
            return
        }
        let index = UInt32(row)

        await model.toggleReveal(index)
        #expect(model.revealedIndex == nil, "one activation revealed the sync credential")
        #expect(model.pendingAccountAction == index)
        #expect(model.revealedValue == nil)

        await model.toggleReveal(index)
        #expect(model.revealedIndex == index)
        #expect(model.revealedValue != nil)
        #expect(model.pendingAccountAction == nil)

        await model.forgetRevealed()
    }

    @Test func anOrdinaryRowRevealsOnTheFirstActivation() async {
        let model = await openSyncShaped()
        guard let row = model.entries.firstIndex(where: {
            !$0.isAccountCredential && !$0.hostname.isEmpty
        }) else {
            Issue.record("sync-shaped carries no ordinary row")
            return
        }
        let index = UInt32(row)

        await model.toggleReveal(index)
        #expect(model.revealedIndex == index)
        #expect(model.revealedValue != nil)

        await model.forgetRevealed()
    }

    /// Moving to another row drops the pending confirmation, so returning to
    /// the account row asks again.
    @Test func leavingTheAccountRowDropsThePendingConfirmation() async {
        let model = await openSyncShaped()
        guard let accountRow = model.entries.firstIndex(where: { $0.isAccountCredential }),
              let otherRow = model.entries.firstIndex(where: {
                  !$0.isAccountCredential && !$0.hostname.isEmpty
              })
        else {
            Issue.record("sync-shaped is missing a row this test needs")
            return
        }

        await model.toggleReveal(UInt32(accountRow))
        #expect(model.pendingAccountAction == UInt32(accountRow))

        await model.toggleReveal(UInt32(otherRow))
        #expect(model.pendingAccountAction == nil)

        // The other row stays revealed through this, the same way the TUI
        // leaves it. Only the account row has to ask again.
        await model.toggleReveal(UInt32(accountRow))
        #expect(model.revealedIndex != UInt32(accountRow), "the account row revealed without a fresh confirmation")
        #expect(model.pendingAccountAction == UInt32(accountRow))

        await model.forgetRevealed()
    }

    /// `copy(at:)` decrypts, hands the string to the clipboard and wipes the
    /// buffer. The row it copied stays masked.
    @Test func copyingAnOrdinaryRowLeavesItMasked() async {
        let clipboard = ClipboardSpy()
        let model = await openSyncShaped(clipboard: clipboard)
        guard let row = model.entries.firstIndex(where: {
            !$0.isAccountCredential && !$0.hostname.isEmpty
        }) else {
            Issue.record("sync-shaped carries no ordinary row")
            return
        }

        await model.copy(at: UInt32(row))
        #expect(clipboard.written.count == 1)
        #expect(clipboard.written.first?.isEmpty == false)
        #expect(model.statusMessage == "Copied")
        #expect(model.revealedIndex == nil, "copying revealed the row")
        #expect(model.pendingAccountAction == nil)
    }

    @Test func copyingTheAccountRowNeedsASecondActivation() async {
        let clipboard = ClipboardSpy()
        let model = await openSyncShaped(clipboard: clipboard)
        guard let row = model.entries.firstIndex(where: { $0.isAccountCredential }) else {
            Issue.record("sync-shaped carries no account credential row")
            return
        }
        let index = UInt32(row)

        await model.copy(at: index)
        #expect(clipboard.written.isEmpty, "one activation copied the sync credential")
        #expect(model.pendingAccountAction == index)

        await model.copy(at: index)
        #expect(clipboard.written.count == 1)
        #expect(model.statusMessage == "Copied")
        #expect(model.pendingAccountAction == nil)
        #expect(model.revealedIndex == nil, "copying revealed the account row")
    }

    /// Confirming a copy answers that copy. Revealing afterwards is a second
    /// decision.
    @Test func revealingAfterAConfirmedCopyAsksAgain() async {
        let model = await openSyncShaped()
        guard let row = model.entries.firstIndex(where: { $0.isAccountCredential }) else {
            Issue.record("sync-shaped carries no account credential row")
            return
        }
        let index = UInt32(row)

        await model.copy(at: index)
        await model.copy(at: index)

        await model.toggleReveal(index)
        #expect(model.revealedIndex == nil, "the account row revealed without a fresh confirmation")
        #expect(model.pendingAccountAction == index)

        await model.forgetRevealed()
    }

    /// An unmigrated profile holds des_ede3_cbc entries this project cannot
    /// decrypt. The copy reports that and writes nothing.
    @Test func copyingA3DESRowReportsTheErrorAndWritesNothing() async {
        let clipboard = ClipboardSpy()
        let model = AppModel(clipboard: clipboard.write)
        await model.selectProfile(Profile(id: 0, path: fixture("unmigrated")))
        #expect(model.entries.isEmpty == false, "the unmigrated fixture did not open")

        await model.copy(at: 0)
        #expect(clipboard.written.isEmpty)
        #expect(model.statusMessage == KeywiseError.legacy3DES.errorDescription)
    }

    /// The app gives a revealed password 30 seconds. This model gets 50 ms.
    @Test func aRevealedPasswordMasksItselfAfterTheTimeout() async throws {
        let model = await openSyncShaped(revealTimeout: .milliseconds(50))
        guard let row = model.entries.firstIndex(where: {
            !$0.isAccountCredential && !$0.hostname.isEmpty
        }) else {
            Issue.record("sync-shaped carries no ordinary row")
            return
        }

        await model.toggleReveal(UInt32(row))
        #expect(model.revealedIndex == UInt32(row))

        try await Task.sleep(for: .milliseconds(400))
        #expect(model.revealedIndex == nil, "the reveal outlived its timeout")
        #expect(model.revealedValue == nil)
        #expect(model.statusMessage == "5 logins")
    }

    /// Hiding by hand cancels the timer, so a later reveal keeps its own.
    @Test func hidingByHandCancelsTheTimer() async throws {
        let model = await openSyncShaped(revealTimeout: .milliseconds(50))
        guard let row = model.entries.firstIndex(where: {
            !$0.isAccountCredential && !$0.hostname.isEmpty
        }) else {
            Issue.record("sync-shaped carries no ordinary row")
            return
        }

        await model.toggleReveal(UInt32(row))
        await model.toggleReveal(UInt32(row))
        #expect(model.revealedIndex == nil)

        let model2 = await openSyncShaped(revealTimeout: .seconds(30))
        await model2.toggleReveal(UInt32(row))
        try await Task.sleep(for: .milliseconds(400))
        #expect(model2.revealedIndex == UInt32(row), "a 30 second timeout fired early")

        await model2.forgetRevealed()
    }
}
