import AppKit
import Observation
import Testing
@testable import FirefoxPasswordView

/// SwiftUI re-invokes EntryTableView.updateNSView only when a property the
/// enclosing body read has changed. Holding an @Observable reference
/// registers nothing. Reading `matchedIndices` solely inside
/// Coordinator.reload put the read where SwiftUI does not track it, so on a
/// cold open the table reloaded once against an empty AppModel and never
/// again: matchedIndices is assigned after ffpw_entries returns, and no
/// invalidation followed it.
@MainActor
struct EntryListViewTests {
    /// withObservationTracking's onChange is @Sendable, so it cannot capture
    /// and mutate a local var under swift-tools-version 6.0.
    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    @Test func entryListViewBodyTracksMatchedIndices() async {
        let model = await openSyncShaped()
        #expect(model.matchedIndices.count == 5)

        // Registering after the profile is open leaves matchedIndices as the
        // only tracked property this test then changes. selectProfile also
        // writes statusMessage and entries, so registering before it would
        // pass on a body that read either of those and never touched
        // matchedIndices.
        let flag = Flag()
        withObservationTracking {
            _ = EntryListView(model: model).body
        } onChange: {
            flag.fired = true
        }

        // searchText is not read by the body, so setting it registers
        // nothing. runSearch assigns matchedIndices and nothing else.
        model.searchText = "sub.example.org"
        await model.runSearch()

        #expect(model.matchedIndices.count == 1, "runSearch did not narrow the match set")
        #expect(flag.fired, "EntryListView.body must read matchedIndices, or the table never reloads after a cold open")
    }

    /// `numberOfRows` answers from the coordinator's own snapshot, so these
    /// counts also assert that each reload updated it.
    @Test func reloadFillsTheTableWhenIndicesArriveAfterAnEmptyUpdate() async {
        let model = await openSyncShaped()
        let (coordinator, table) = makeTable(for: model)

        // The cold open: the first update runs before the entries land.
        coordinator.reload(table, entries: [], matchedIndices: [], revealedIndex: nil)
        #expect(table.numberOfRows == 0)

        coordinator.reload(table, entries: model.entries, matchedIndices: model.matchedIndices, revealedIndex: nil)
        #expect(table.numberOfRows == 5)

        // Revealing changes no index, and takes the per-row reload branch.
        // The rows have to survive it.
        coordinator.reload(table, entries: model.entries, matchedIndices: model.matchedIndices, revealedIndex: model.matchedIndices[0])
        #expect(table.numberOfRows == 5)
    }

    /// The launch race: ContentView's `.task(id: searchText)` can publish
    /// matchedIndices while AppModel.loadEntries has not assigned entries
    /// yet. Every row then builds with `entry: nil` and draws EmptyView at
    /// full height, so the list looks empty while the status bar counts the
    /// logins. The entries assignment that follows has to reload the table.
    @Test func entriesArrivingAfterTheIndicesReloadsTheRows() async {
        let model = await openSyncShaped()
        let (coordinator, table) = makeTable(for: model)

        // Indices first, entries still empty.
        coordinator.reload(table, entries: [], matchedIndices: model.matchedIndices, revealedIndex: nil)
        #expect(table.numberOfRows == 5)
        #expect(coordinator.entry(forRow: 0) == nil, "no entry is available yet")

        // Entries land. The row count is unchanged, so only tracking
        // entries can trigger the reload that fills the rows.
        coordinator.reload(table, entries: model.entries, matchedIndices: model.matchedIndices, revealedIndex: nil)
        #expect(coordinator.entry(forRow: 0) != nil, "rows still render EmptyView after entries arrived")
    }
}
