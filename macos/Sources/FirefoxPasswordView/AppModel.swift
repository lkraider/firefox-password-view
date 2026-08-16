import Foundation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    private(set) var profiles: [Profile] = []
    var selectedProfile: Profile?

    private var store = FFPWStore()
    private(set) var matchedIndices: [UInt32] = []
    private(set) var entries: [UInt32: Entry] = [:]

    var searchText: String = "" {
        didSet { Task { await runSearch() } }
    }

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
            let (needsPw, error) = await store.open(profilePath: profile.path)
            if error == nil {
                selectedProfile = profile
                needsPassword = needsPw
                if !needsPw { await loadEntries() }
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
        entries = [:]
        matchedIndices = []
        searchText = ""
        passwordInput = ""
        passwordError = false

        let (needsPw, error) = await store.open(profilePath: profile.path)
        needsPassword = needsPw
        if let error {
            statusMessage = error.localizedDescription
            return
        }
        if !needsPw {
            await loadEntries()
        }
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
        let count = await store.count()
        statusMessage = "\(count) logins"
        await runSearch()
    }

    private func runSearch() async {
        matchedIndices = await store.search(searchText)

        // Fetched into a plain local dictionary and published once: setting
        // `entries` inside this loop, one key at a time, made @Observable
        // fire a change on every single assignment. SwiftUI re-evaluated the
        // full 1701-row list on each of those, turning one search into
        // O(n^2) work and pinning a core at 100% for the entire load.
        var updated = entries
        for index in matchedIndices where updated[index] == nil {
            if let entry = await store.entry(at: index) {
                updated[index] = entry
            }
        }
        entries = updated
    }

    func toggleReveal(_ index: UInt32) async {
        if revealedIndex == index {
            await forgetRevealed()
            return
        }
        await forgetRevealed()
        switch await store.reveal(at: index) {
        case .success(let secret):
            revealedIndex = index
            revealedSecret = secret
        case .failure(let error):
            statusMessage = error.localizedDescription
        }
    }

    func forgetRevealed() async {
        if let secret = revealedSecret {
            await secret.forget()
        }
        revealedSecret = nil
        revealedIndex = nil
    }

    func copyRevealed() {
        guard let value = revealedSecret?.value else { return }
        ClipboardWriter.copy(value)
        statusMessage = "Copied"
    }
}
