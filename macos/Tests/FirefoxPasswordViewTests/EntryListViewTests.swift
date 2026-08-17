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
    private func fixture(_ name: String) -> String {
        "../core/testdata/\(name)"
    }

    /// withObservationTracking's onChange is @Sendable, so it cannot capture
    /// and mutate a local var under swift-tools-version 6.0.
    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    @Test func entryListViewBodyTracksMatchedIndices() async {
        let model = AppModel()
        await model.selectProfile(Profile(id: 0, path: fixture("sync-shaped")))
        #expect(model.matchedIndices.count == 5)

        // Registering after the profile is open leaves matchedIndices as the
        // only tracked property this test then changes. Registering before
        // would also catch a body that reads statusMessage or entries, which
        // selectProfile writes too, and the test would pass without the
        // dependency it exists to prove.
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
}
