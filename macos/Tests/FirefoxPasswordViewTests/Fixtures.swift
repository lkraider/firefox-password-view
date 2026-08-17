import AppKit
@testable import FirefoxPasswordView

/// The committed profiles under core/testdata. swift test runs from
/// `macos/`, so the paths are relative to it. See core/testdata/README.md
/// for what each one holds and which password it was written with.
func fixture(_ name: String) -> String {
    "../core/testdata/\(name)"
}

/// The sync-shaped fixture, opened. It carries five entries, one of them the
/// chrome://FirefoxAccounts row and one a moz-extension:// row, plus two
/// tombstones the store filters out.
@MainActor
func openSyncShaped() async -> AppModel {
    let model = AppModel()
    await model.selectProfile(Profile(id: 0, path: fixture("sync-shaped")))
    return model
}

/// An NSTableView wired to a Coordinator, as makeNSView wires it. Call
/// `reload` on the coordinator and read `table.numberOfRows` back.
@MainActor
func makeTable(for model: AppModel) -> (EntryTableView.Coordinator, NSTableView) {
    let coordinator = EntryTableView.Coordinator(model: model)
    let table = NSTableView()
    table.addTableColumn(NSTableColumn(identifier: .init("main")))
    table.dataSource = coordinator
    table.delegate = coordinator
    return (coordinator, table)
}
