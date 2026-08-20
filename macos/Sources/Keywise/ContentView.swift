import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            EntryListView(model: model)
                .searchable(text: $model.searchText, prompt: "Search logins")
                .navigationTitle("Keywise")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ProfilePicker(model: model)
                    }
                }
                .overlay { LoadingIndicator(model: model) }
                .safeAreaInset(edge: .bottom) { StatusBar(model: model) }
                // SwiftUI cancels the running task and starts a new one
                // whenever searchText changes. It sits on ContentView, which
                // already reads searchText through .searchable above. On
                // EntryListView it would add searchText to that view's
                // dependencies, and the NSTableView would re-render on every
                // keystroke.
                .task(id: model.searchText) { await model.runSearch() }
        }
        .sheet(isPresented: Binding(get: { model.needsPassword }, set: { _ in })) {
            PrimaryPasswordSheet(model: model)
        }
    }
}

/// Owns the table's dependency set. SwiftUI tracks the properties a body
/// reads, so reading `entries`, `matchedIndices` and `revealedIndex` here
/// re-invokes EntryTableView.updateNSView when one of them changes. A read
/// inside the representable's own callbacks goes untracked. Drop one read
/// and the table keeps drawing what it drew before that property was
/// assigned, for the life of the window.
///
/// The body reads nothing else, so a statusMessage write, a copy or a
/// loading spinner leaves the table alone.
///
/// The type is internal so EntryListViewTests can evaluate this body inside
/// withObservationTracking.
struct EntryListView: View {
    let model: AppModel

    var body: some View {
        EntryTableView(
            model: model,
            entries: model.entries,
            matchedIndices: model.matchedIndices,
            revealedIndex: model.revealedIndex
        )
    }
}

/// Reads only `profiles` and `selectedProfile`.
private struct ProfilePicker: View {
    let model: AppModel

    var body: some View {
        // profiles.count > 1 turns true before start() picks a profile. The
        // binding would read nil then, and nil has no tag among the options
        // below. AppKit logs that as an invalid Picker configuration.
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
