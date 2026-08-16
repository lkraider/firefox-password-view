import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            // AppKit logs "reentrant operation in its NSTableView delegate"
            // once during the initial load of a large profile. Not a crash
            // today; macOS's own release notes mark it a future assert.
            // Needs Instruments to chase further; follow up before release.
            List(model.matchedIndices, id: \.self) { index in
                if let entry = model.entries[index] {
                    EntryRow(
                        entry: entry,
                        isRevealed: model.revealedIndex == index,
                        revealedValue: model.revealedIndex == index ? model.revealedValue : nil,
                        onToggleReveal: { Task { await model.toggleReveal(index) } },
                        onCopy: { model.copyRevealed() }
                    )
                }
            }
            .searchable(text: $model.searchText, prompt: "Search logins")
            .navigationTitle("Firefox Passwords")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if model.profiles.count > 1 {
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
            .overlay {
                if model.isLoading {
                    ProgressView()
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(model.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
            }
        }
        .sheet(isPresented: Binding(get: { model.needsPassword }, set: { _ in })) {
            PrimaryPasswordSheet(model: model)
        }
    }
}

private struct EntryRow: View {
    let entry: Entry
    let isRevealed: Bool
    let revealedValue: String?
    let onToggleReveal: () -> Void
    let onCopy: () -> Void

    var body: some View {
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
                        Text(revealedValue ?? "").textSelection(.enabled)
                    } else {
                        Text("••••••••")
                    }
                }
                .font(.system(.body, design: .monospaced))
            }
            Spacer()
            if isRevealed {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy password")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleReveal)
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
