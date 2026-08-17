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
                // Cancels the in-flight search and starts a new one whenever
                // searchText changes, replacing a hand-rolled Task/cancel
                // pair with the same behavior SwiftUI already provides.
                // ContentView already reads searchText via .searchable's
                // binding above, so this adds no new tracked dependency;
                // attaching it to EntryListView instead would make that view
                // (and its NSTableView) re-render on every keystroke, which
                // the matchedIndices-only split above exists to avoid.
                .task(id: model.searchText) { await model.runSearch() }
        }
        .sheet(isPresented: Binding(get: { model.needsPassword }, set: { _ in })) {
            PrimaryPasswordSheet(model: model)
        }
    }
}

/// Owns the table's dependency set. Reading `matchedIndices` and
/// `revealedIndex` here is what makes SwiftUI re-invoke
/// EntryTableView.updateNSView when either changes; a read inside the
/// representable's own callbacks is not tracked. Keep both reads. Without
/// them the table reloads once against an empty AppModel on a cold open and
/// never again, because matchedIndices is assigned after ffpw_entries
/// returns and nothing invalidates this view.
///
/// These two are also the whole dependency set, so statusMessage changing,
/// a copy, or a loading spinner still leaves the table alone.
///
/// Internal rather than private so EntryListViewTests can evaluate this
/// body inside withObservationTracking.
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
