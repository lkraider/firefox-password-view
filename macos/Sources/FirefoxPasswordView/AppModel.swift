import Foundation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    private(set) var profiles: [Profile] = []
    var selectedProfile: Profile?

    private var store = FFPWStore()
    private(set) var matchedIndices: [UInt32] = []
    /// Every entry's display data, fetched once when the profile opens.
    /// Hostnames and usernames are already decrypted by then, so indexing
    /// into this array is the whole cost of showing a row: no per-row fetch,
    /// no per-row loading state.
    private(set) var entries: [Entry] = []

    /// ContentView drives runSearch from a `.task(id: searchText)`. That
    /// cancels the in-flight search and starts a new one on every change
    /// here, so nothing in this file tracks or cancels a Task by hand.
    var searchText: String = ""

    private(set) var needsPassword = false
    var passwordInput = ""
    private(set) var passwordError = false

    private(set) var revealedIndex: UInt32?
    private var revealedSecret: Secret?
    var revealedValue: String? { revealedSecret?.value }

    private(set) var statusMessage = ""
    private(set) var isLoading = false

    /// Tries every enumerated profile in turn and stops at the first one
    /// that actually has a key4.db (opens or needs a password), the same
    /// distinction ffpw_open reports. A profile Firefox has abandoned, like
    /// the one the legacy Default=1 flag can point at, is skipped rather
    /// than shown as the initial pick.
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

    /// Opens `profile`, updates `needsPassword`, and loads its entries if it
    /// needs no password. Returns the error on failure, so `start()` can try
    /// the next profile silently while `selectProfile()` shows it directly.
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

    /// Called by `loadEntries` directly and by ContentView's
    /// `.task(id: searchText)` on every keystroke. A search superseded by a
    /// newer keystroke must not overwrite the newer one's results if it
    /// happens to finish later, so this is followed by a check.
    func runSearch() async {
        let indices = await store.search(searchText)
        guard !Task.isCancelled else { return }
        matchedIndices = indices
    }

    /// The entry a second activation reveals. The
    /// `chrome://FirefoxAccounts` password is Mozilla Account sync key
    /// material, so revealing it hands over the account. The TUI asks for a
    /// second `enter` on that row. This does the same for a click, a
    /// keypress and an accessibility action.
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
            // Clears the confirmation prompt once the row is showing, so
            // the status bar stops asking for something already done.
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
