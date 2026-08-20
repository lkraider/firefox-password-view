import Foundation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    private(set) var profiles: [Profile] = []
    var selectedProfile: Profile?

    private var store = KeywiseStore()
    private(set) var matchedIndices: [UInt32] = []
    /// Fetched once when the profile opens. The core decrypts every hostname
    /// and username during that open, so drawing a row is one index into
    /// this array.
    private(set) var entries: [Entry] = []

    /// ContentView drives runSearch from a `.task(id: searchText)`. SwiftUI
    /// cancels the running search and starts a new one on every change here.
    /// This file holds no Task of its own.
    var searchText: String = ""

    private(set) var needsPassword = false
    var passwordInput = ""
    private(set) var passwordError = false

    private(set) var revealedIndex: UInt32?
    private var revealedSecret: Secret?
    var revealedValue: String? { revealedSecret?.value }

    private(set) var statusMessage = ""
    private(set) var isLoading = false

    /// Injected so the test suite can read back what a copy wrote without
    /// putting a fixture password on the developer's pasteboard.
    @ObservationIgnored private let writeToClipboard: @MainActor (String) -> Void

    /// A revealed password masks itself again after this long, the same 30
    /// seconds `ClipboardWriter` gives a copied one. The tests pass a short
    /// one.
    @ObservationIgnored private let revealTimeout: Duration
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    init(
        clipboard: @escaping @MainActor (String) -> Void = ClipboardWriter.copy,
        revealTimeout: Duration = .seconds(30)
    ) {
        writeToClipboard = clipboard
        self.revealTimeout = revealTimeout
    }

    /// profiles.ini lists profiles Firefox abandoned, including the one the
    /// legacy Default=1 flag points at. Those have no key4.db, and keywise_open
    /// fails on them. A profile that has one either opens or reports
    /// KEYWISE_ERR_NEEDS_PASSWORD, and `attemptOpen` returns nil for both.
    func start() async {
        profiles = listProfiles()
        for profile in profiles {
            if await attemptOpen(profile) == nil {
                selectedProfile = profile
                return
            }
            await store.close()
        }
        statusMessage = profiles.isEmpty ? "No Firefox profile found" : "No profile with saved logins found"
    }

    func selectProfile(_ profile: Profile) async {
        await forgetRevealed()
        await store.close()
        store = KeywiseStore()
        selectedProfile = profile
        entries = []
        matchedIndices = []
        searchText = ""
        passwordInput = ""
        passwordError = false

        if let error = await attemptOpen(profile) {
            statusMessage = error.localizedDescription
        }
    }

    /// Hands the error back to the caller. `start()` moves on to the next
    /// profile. `selectProfile()` puts the message in the status bar.
    private func attemptOpen(_ profile: Profile) async -> KeywiseError? {
        let (needsPw, error) = await store.open(profilePath: profile.path)
        needsPassword = needsPw
        if let error { return error }
        if !needsPw {
            await loadEntries()
        }
        return nil
    }

    func submitPassword() async {
        passwordError = false
        if let error = await store.unlock(password: passwordInput) {
            passwordError = true
            statusMessage = error.localizedDescription
            return
        }
        needsPassword = false
        passwordInput = ""
        await loadEntries()
    }

    private func loadEntries() async {
        isLoading = true
        defer { isLoading = false }
        entries = await store.entries()
        statusMessage = entryCountMessage
        await runSearch()
    }

    /// ContentView cancels this task on every keystroke. The cancelled call
    /// still returns its indices, and they belong to the older query.
    func runSearch() async {
        let indices = await store.search(searchText)
        guard !Task.isCancelled else { return }
        matchedIndices = indices
    }

    /// The `chrome://FirefoxAccounts` password is Mozilla Account sync key
    /// material. Whoever reads it holds the account. Revealing and copying
    /// both ask for a second activation on that row, and each clears this
    /// before it acts, so the next action asks again.
    private(set) var pendingAccountAction: UInt32?

    private func isAccountRow(_ index: UInt32) -> Bool {
        let i = Int(index)
        return i < entries.count && entries[i].isAccountCredential
    }

    func toggleReveal(_ index: UInt32) async {
        if revealedIndex == index {
            await forgetRevealed()
            return
        }
        if isAccountRow(index), pendingAccountAction != index {
            pendingAccountAction = index
            statusMessage = "This reveals Firefox Sync account credentials. Activate again to confirm."
            return
        }
        pendingAccountAction = nil
        await forgetRevealed()
        switch await store.reveal(at: index) {
        case .success(let secret):
            revealedIndex = index
            revealedSecret = secret
            startHideTimer(for: index)
            // Drops the confirmation prompt this reveal answered.
            statusMessage = entryCountMessage
        case .failure(let error):
            statusMessage = error.localizedDescription
        }
    }

    private var entryCountMessage: String {
        "\(entries.count) logins"
    }

    func forgetRevealed() async {
        hideTask?.cancel()
        hideTask = nil
        if let secret = revealedSecret {
            await secret.forget()
        }
        revealedSecret = nil
        revealedIndex = nil
        pendingAccountAction = nil
    }

    /// A person walks away from a revealed password and it stays on screen
    /// until something else hides it. This masks the row `revealTimeout`
    /// after the reveal. Each reveal restarts the count, and
    /// `forgetRevealed` cancels it.
    private func startHideTimer(for index: UInt32) {
        hideTask?.cancel()
        let timeout = revealTimeout
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.hideRevealedAfterTimeout(index)
        }
    }

    /// Hides only the row the timer was started for. A reveal of another row
    /// starts its own timer, and this one has nothing left to do.
    private func hideRevealedAfterTimeout(_ index: UInt32) async {
        guard revealedIndex == index else { return }
        await forgetRevealed()
        statusMessage = entryCountMessage
    }

    /// The password never reaches the screen here. The core decrypts on
    /// demand, the clipboard takes the string, and `forget()` wipes the C
    /// buffer before this returns. `revealedIndex` is left alone, so the row
    /// stays masked.
    func copy(at index: UInt32) async {
        if isAccountRow(index), pendingAccountAction != index {
            pendingAccountAction = index
            statusMessage = "This copies Firefox Sync account credentials to the clipboard. Activate again to confirm."
            return
        }
        pendingAccountAction = nil
        switch await store.reveal(at: index) {
        case .success(let secret):
            writeToClipboard(secret.value)
            await secret.forget()
            statusMessage = "Copied"
        case .failure(let error):
            statusMessage = error.localizedDescription
        }
    }
}
