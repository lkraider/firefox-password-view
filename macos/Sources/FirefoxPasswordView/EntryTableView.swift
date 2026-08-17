import AppKit
import SwiftUI

/// Wraps NSTableView directly instead of SwiftUI's List. List's macOS
/// backing NSTableView only supports self-sizing (usesAutomaticRowHeights),
/// which estimates the height of rows it has never measured and corrects
/// once it measures them; dragging the scrollbar knob jumps to an arbitrary
/// position instantly, so that correction is visible as a stutter. A
/// constant rowHeight here gives NSTableView O(1) scroll-position math
/// (rowHeight × row count) with nothing left to estimate.
struct EntryTableView: NSViewRepresentable {
    let model: AppModel

    /// Passed in as values by EntryListView, whose body reads them. That
    /// read is what registers the Observation dependency SwiftUI uses to
    /// re-invoke `updateNSView`. Reading them here through `model` instead
    /// registers nothing, because SwiftUI tracks reads made while it
    /// evaluates a body, not reads made inside a representable's callbacks.
    ///
    /// A row's content needs all three. `entries` belongs here even though
    /// only `viewFor` reads it: AppModel publishes `entries` and
    /// `matchedIndices` separately, and ContentView's
    /// `.task(id: searchText)` can land `matchedIndices` first, while
    /// `entries` is still empty. Every row then builds with `entry: nil` and
    /// draws EmptyView at full row height. Without `entries` tracked, the
    /// assignment that follows reloads nothing and the rows stay blank.
    let entries: [Entry]
    let matchedIndices: [UInt32]
    let revealedIndex: UInt32?

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = EntryRowContent.height
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 0)

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.model = model
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.reload(tableView, entries: entries, matchedIndices: matchedIndices, revealedIndex: revealedIndex)
    }

    /// `reload` takes the match set and the revealed index as arguments, so
    /// it acts on the same snapshot that triggered the update. EntryListView
    /// reads exactly those two properties, so an unrelated AppModel change
    /// (statusMessage, isLoading, ...) still never reloads this table.
    /// @MainActor because it reads AppModel (MainActor-isolated) and drives
    /// NSTableView (also MainActor-isolated); AppKit calls its data
    /// source/delegate methods from the main thread regardless.
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: AppModel
        private var lastEntries: [Entry] = []
        private var lastMatchedIndices: [UInt32] = []
        private var lastRevealedIndex: UInt32?

        init(model: AppModel) {
            self.model = model
        }

        /// Reloads everything when the match set or the entries changed;
        /// reveals toggling reloads just the one or two affected rows.
        ///
        /// `entries` is compared by count. AppModel only ever assigns it
        /// wholesale, and the one path that swaps entries for a same-sized
        /// set (selectProfile) clears matchedIndices on the way, which the
        /// first comparison catches. An element-wise compare would run over
        /// every entry on each keystroke to learn nothing.
        func reload(_ tableView: NSTableView, entries: [Entry], matchedIndices indices: [UInt32], revealedIndex revealed: UInt32?) {
            if indices != lastMatchedIndices || entries.count != lastEntries.count {
                lastEntries = entries
                lastMatchedIndices = indices
                lastRevealedIndex = revealed
                tableView.reloadData()
                return
            }
            guard revealed != lastRevealedIndex else { return }

            var rows = IndexSet()
            if let old = lastRevealedIndex, let row = indices.firstIndex(of: old) {
                rows.insert(row)
            }
            if let new = revealed, let row = indices.firstIndex(of: new) {
                rows.insert(row)
            }
            lastRevealedIndex = revealed
            if !rows.isEmpty {
                tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
            }
        }

        /// Answers from `lastMatchedIndices`, the snapshot the last reload
        /// ran against. Reading `model.matchedIndices` here reports a count
        /// AppKit has not been told to reload for, so between an AppModel
        /// write and the reload that follows it, the row count and the rows
        /// come from different match sets.
        func numberOfRows(in tableView: NSTableView) -> Int {
            lastMatchedIndices.count
        }

        /// The entry a row draws, from the snapshot the last reload ran
        /// against. nil makes EntryRowContent draw EmptyView at full row
        /// height, which is what an empty list with the right row count is.
        func entry(forRow row: Int) -> Entry? {
            guard row < lastMatchedIndices.count else { return nil }
            let i = Int(lastMatchedIndices[row])
            return i < lastEntries.count ? lastEntries[i] : nil
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("EntryCell")
            let hostingView: NSHostingView<EntryRowContent>
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSHostingView<EntryRowContent> {
                hostingView = reused
            } else {
                hostingView = NSHostingView(rootView: EntryRowContent(entry: nil, isRevealed: false, revealedValue: nil, onToggleReveal: {}, onCopy: {}))
                hostingView.identifier = identifier
            }

            // Indexed against the same snapshot numberOfRows answered from,
            // so `row` is always in range for it.
            guard row < lastMatchedIndices.count else { return hostingView }
            let index = lastMatchedIndices[row]
            let entry = entry(forRow: row)
            // Both of these come from the model, so the flag and the secret
            // below always describe the same entry. Taking the flag from
            // lastRevealedIndex instead pairs one row's flag with another
            // row's secret whenever a reveal lands before its reload does.
            let isRevealed = model.revealedIndex == index
            let model = self.model
            hostingView.rootView = EntryRowContent(
                entry: entry,
                isRevealed: isRevealed,
                revealedValue: isRevealed ? model.revealedValue : nil,
                onToggleReveal: { Task { await model.toggleReveal(index) } },
                onCopy: { model.copyRevealed() }
            )
            return hostingView
        }
    }
}

/// One row's visual content, hosted inside the NSTableView cell above via
/// NSHostingView. Pure and stateless: every value it needs is passed in.
struct EntryRowContent: View {
    static let height: CGFloat = 56

    let entry: Entry?
    let isRevealed: Bool
    let revealedValue: String?
    let onToggleReveal: () -> Void
    let onCopy: () -> Void

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
                                .lineLimit(1)
                        }
                        Text(entry.username)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Group {
                            if isRevealed {
                                Text(revealedValue ?? "").textSelection(.enabled)
                            } else {
                                Text("••••••••")
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
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
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggleReveal)
            } else {
                EmptyView()
            }
        }
        .frame(height: Self.height)
    }
}
