import Testing
@testable import FirefoxPasswordView

@MainActor
struct AppModelTests {
    /// The chrome://FirefoxAccounts password is Mozilla Account sync key
    /// material, so one activation must not show it.
    @Test func theAccountRowNeedsASecondActivation() async {
        let model = await openSyncShaped()
        guard let row = model.entries.firstIndex(where: { $0.isAccountCredential }) else {
            Issue.record("sync-shaped carries no account credential row")
            return
        }
        let index = UInt32(row)

        await model.toggleReveal(index)
        #expect(model.revealedIndex == nil, "one activation revealed the sync credential")
        #expect(model.pendingAccountReveal == index)
        #expect(model.revealedValue == nil)

        await model.toggleReveal(index)
        #expect(model.revealedIndex == index)
        #expect(model.revealedValue != nil)
        #expect(model.pendingAccountReveal == nil)

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
        #expect(model.pendingAccountReveal == UInt32(accountRow))

        await model.toggleReveal(UInt32(otherRow))
        #expect(model.pendingAccountReveal == nil)

        // The other row stays revealed through this, the same way the TUI
        // leaves it. Only the account row has to ask again.
        await model.toggleReveal(UInt32(accountRow))
        #expect(model.revealedIndex != UInt32(accountRow), "the account row revealed without a fresh confirmation")
        #expect(model.pendingAccountReveal == UInt32(accountRow))

        await model.forgetRevealed()
    }
}
