import Foundation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    private(set) var profiles: [Profile] = []
    var selectedProfile: Profile?

    private var store = FFPWStore()
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

    /// profiles.ini lists profiles Firefox abandoned, including the one the
    /// legacy Default=1 flag points at. Those have no key4.db, and ffpw_open
    /// fails on them. A profile that has one either opens or reports
    /// FFPW_ERR_NEEDS_PASSWORD, and `attemptOpen` returns nil for both.
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
        store = FFPWStore()
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
    private func attemptOpen(_ profile: Profile) async -> FFPWError? {
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
    /// material. Whoever reads it holds the account. Both front ends ask for
    /// a second activation on that row.
    private(set) var pendingAccountReveal: UInt32?

    func toggleReveal(_ index: UInt32) async {
        if revealedIndex == index {
            await forgetRevealed()
            return
        }
        let i = Int(index)
        let isAccount = i < entries.count && entries[i].isAccountCredential
        if isAccount, pendingAccountReveal != index {
            pendingAccountReveal = index
            statusMessage = "This reveals Firefox Sync account credentials. Activate again to confirm."
            return
        }
        pendingAccountReveal = nil
        await forgetRevealed()
        switch await store.reveal(at: index) {
        case .success(let secret):
            revealedIndex = index
            revealedSecret = secret
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
        if let secret = revealedSecret {
            await secret.forget()
        }
        revealedSecret = nil
        revealedIndex = nil
        pendingAccountReveal = nil
    }

    func copyRevealed() {
        guard let value = revealedSecret?.value else { return }
        ClipboardWriter.copy(value)
        statusMessage = "Copied"
    }
}
