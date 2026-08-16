import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            EntryListView(model: model)
                .searchable(text: $model.searchText, prompt: "Search logins")
                .navigationTitle("Firefox Passwords")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ProfilePicker(model: model)
                    }
                }
                .overlay { LoadingIndicator(model: model) }
                .safeAreaInset(edge: .bottom) { StatusBar(model: model) }
        }
        .sheet(isPresented: Binding(get: { model.needsPassword }, set: { _ in })) {
            PrimaryPasswordSheet(model: model)
        }
    }
}

/// Reads only `matchedIndices`. Copying a password, a loading spinner
/// toggling, or any other `AppModel` change that this view does not read
/// leaves this view's Observation tracking untouched, so `List` never
/// re-diffs its up-to-1701-row data source for an unrelated event; it was
/// re-diffing on every one of those before this view existed, since they
/// all used to invalidate one `ContentView.body` that read everything.
private struct EntryListView: View {
    let model: AppModel

    var body: some View {
        List(model.matchedIndices, id: \.self) { index in
            EntryRow(model: model, index: index)
        }
    }
}

/// Reads only `profiles` and `selectedProfile`.
private struct ProfilePicker: View {
    let model: AppModel

    var body: some View {
        // Gated on selectedProfile so the Picker's binding never starts out
        // nil: profiles.count > 1 is already true before start() picks one,
        // and nil has no tag among the options below, which AppKit logs as
        // an invalid Picker configuration.
        if model.profiles.count > 1, model.selectedProfile != nil {
            Picker("Profile", selection: Binding(
                get: { model.selectedProfile?.id },
                set: { newId in
                    if let profile = model.profiles.first(where: { $0.id == newId }) {
                        Task { await model.selectProfile(profile) }
                    }
                }
            )) {
                ForEach(model.profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
        }
    }
}

/// Reads only `isLoading`.
private struct LoadingIndicator: View {
    let model: AppModel

    var body: some View {
        if model.isLoading {
            ProgressView()
        }
    }
}

/// Reads only `statusMessage`.
private struct StatusBar: View {
    let model: AppModel

    var body: some View {
        Text(model.statusMessage)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 4)
    }
}

/// Reads its entry directly out of `model.entries`: that array is fully
/// populated once when the profile opens, so this is a synchronous array
/// index, not a fetch. Also reads `model.revealedIndex` directly, so
/// Observation tracks both at this row's granularity: revealing one row
/// invalidates only this view, not every row `List` currently has matched.
private struct EntryRow: View {
    let model: AppModel
    let index: UInt32

    private var entry: Entry? {
        let i = Int(index)
        return i < model.entries.count ? model.entries[i] : nil
    }
    private var isRevealed: Bool { model.revealedIndex == index }

    var body: some View {
        Group {
            if let entry {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if entry.isAccountCredential {
                                Label("Account", systemImage: "person.crop.circle.badge.exclamationmark")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.orange)
                                    .help("Firefox Sync account credential")
                            }
                            if entry.isExtension {
                                Label("Extension", systemImage: "puzzlepiece.extension")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.secondary)
                                    .help("Browser extension")
                            }
                            Text(entry.hostname)
                                .font(.headline)
                        }
                        Text(entry.username)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Group {
                            if isRevealed {
                                Text(model.revealedValue ?? "").textSelection(.enabled)
                            } else {
                                Text("••••••••")
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                    }
                    Spacer()
                    if isRevealed {
                        Button(action: model.copyRevealed) {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy password")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { Task { await model.toggleReveal(index) } }
            } else {
                // matchedIndices only ever holds indices store.search()
                // returned, which are always within entries.count; this
                // branch means that invariant broke, not that data is
                // still loading, so it stays empty rather than showing a
                // spinner that would misreport a bug as normal latency.
                EmptyView()
            }
        }
    }
}

private struct PrimaryPasswordSheet: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("This profile needs its Primary Password")
                .font(.headline)
            SecureField("Primary Password", text: $model.passwordInput)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { Task { await model.submitPassword() } }
            if model.passwordError {
                Text("Wrong password. Try again.")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
            Button("Unlock") { Task { await model.submitPassword() } }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 320)
        .onAppear { focused = true }
    }
}
