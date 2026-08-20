import AppKit
import SwiftUI

/// Wraps NSTableView directly. SwiftUI's List backs onto an NSTableView
/// that only supports self-sizing (usesAutomaticRowHeights). That estimates
/// the height of every row it has never measured, then corrects each one on
/// measuring it. Dragging the scrollbar knob jumps to an arbitrary position
/// instantly, so those corrections show up as a stutter. A constant
/// rowHeight here gives NSTableView O(1) scroll-position math (rowHeight ×
/// row count) with nothing left to estimate.
struct EntryTableView: NSViewRepresentable {
    let model: AppModel

    /// EntryListView's body reads these three and passes them in as values.
    /// SwiftUI tracks the reads a body makes, and that tracking is what
    /// re-invokes `updateNSView`. A read through `model` inside this
    /// representable's callbacks happens outside a body evaluation, and
    /// SwiftUI records it nowhere.
    ///
    /// `entries` is here although only `viewFor` reads it. AppModel
    /// publishes `entries` and `matchedIndices` separately, and ContentView's
    /// `.task(id: searchText)` can land `matchedIndices` while `entries` is
    /// still empty. Every row then builds with `entry: nil` and draws
    /// EmptyView at full row height. Tracking `entries` is what reloads
    /// those rows when the assignment lands.
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
    /// NSTableView (also MainActor-isolated). AppKit calls its data source
    /// and delegate methods from the main thread regardless.
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: AppModel
        private var lastEntries: [Entry] = []
        private var lastMatchedIndices: [UInt32] = []
        private var lastRevealedIndex: UInt32?

        init(model: AppModel) {
            self.model = model
        }

        /// A changed match set or entry count reloads every row. A toggled
        /// reveal reloads the one or two rows it touched.
        ///
        /// `entries` is compared by count, since AppModel assigns it
        /// wholesale. selectProfile swaps entries for a same-sized set, and
        /// it clears matchedIndices on the way, so the first comparison
        /// catches that. An element-wise compare would walk every entry on
        /// each keystroke and report the same answer.
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
        /// ran against. `model.matchedIndices` can already hold a newer set
        /// between an AppModel write and the reload that follows it. AppKit
        /// would then take its row count from one match set and its rows
        /// from another.
        func numberOfRows(in tableView: NSTableView) -> Int {
            lastMatchedIndices.count
        }

        /// The entry a row draws, from the snapshot the last reload ran
        /// against. nil makes EntryRowContent draw EmptyView at full row
        /// height, so the list shows blank rows and the right row count.
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

            // A local, so the two closures below capture it and leave self
            // uncaptured. The table holds the Coordinator, so it outlives
            // both closures.
            let model = self.model

            // Indexed against the same snapshot numberOfRows answered from,
            // so `row` is always in range for it.
            guard row < lastMatchedIndices.count else { return hostingView }
            let index = lastMatchedIndices[row]
            let entry = entry(forRow: row)
            // Both of these come from the model, so the flag and the secret
            // below always describe the same entry. `lastRevealedIndex`
            // still holds the previous row until the reload for a reveal
            // runs, and the flag would then belong to a different row than
            // the secret.
            let isRevealed = model.revealedIndex == index
            hostingView.rootView = EntryRowContent(
                entry: entry,
                isRevealed: isRevealed,
                revealedValue: isRevealed ? model.revealedValue : nil,
                onToggleReveal: { Task { await model.toggleReveal(index) } },
                onCopy: { Task { await model.copy(at: index) } }
            )
            return hostingView
        }
    }
}

/// One row's visual content, hosted inside the NSTableView cell above via
/// NSHostingView. It holds no state. Every value it draws is passed in, so
/// `viewFor` can reuse one hosting view for any row.
struct EntryRowContent: View {
    static let height: CGFloat = 56

    let entry: Entry?
    let isRevealed: Bool
    let revealedValue: String?
    let onToggleReveal: () -> Void
    let onCopy: () -> Void

    /// What VoiceOver reads for the row. It carries the hostname, the
    /// username and the state of the password. The password value stays out
    /// of it, so arrowing down the list speaks no passwords.
    private func label(for entry: Entry) -> String {
        var parts: [String] = []
        if entry.isAccountCredential { parts.append("Firefox Sync account credential") }
        if entry.isExtension { parts.append("Browser extension") }
        parts.append(entry.hostname)
        if !entry.username.isEmpty { parts.append(entry.username) }
        parts.append(isRevealed ? "password shown" : "password hidden")
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Group {
            if let entry {
                // A Button publishes its content as one accessibility
                // element, so nesting the copy button inside the row button
                // dropped copy from the tree. As siblings both appear.
                // A Button also carries an accessibility action. The tap
                // gesture used here before carried none, and a mouse click
                // was the only way to reveal a password.
                HStack(spacing: 0) {
                    Button(action: onToggleReveal) { fields(entry) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(label(for: entry))
                        .accessibilityHint(isRevealed ? "Hides the password" : "Reveals the password")
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy password")
                    .accessibilityLabel("Copy password")
                    .accessibilityHint("Copies without showing the password")
                    .padding(.trailing, 8)
                }
            }
        }
        .frame(height: Self.height)
    }

    private func fields(_ entry: Entry) -> some View {
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
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}
