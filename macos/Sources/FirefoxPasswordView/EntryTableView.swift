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
        context.coordinator.reload(tableView)
    }

    /// Reads model state only inside `reload`, which SwiftUI calls through
    /// the same Observation tracking as a body, so an unrelated AppModel
    /// change (statusMessage, isLoading, ...) never triggers a reload here.
    /// @MainActor because it reads AppModel (MainActor-isolated) and drives
    /// NSTableView (also MainActor-isolated); AppKit calls its data
    /// source/delegate methods from the main thread regardless.
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: AppModel
        private var lastMatchedIndices: [UInt32] = []
        private var lastRevealedIndex: UInt32?

        init(model: AppModel) {
            self.model = model
        }

        /// Reloads everything only when the actual match set changed;
        /// reveals toggling reloads just the one or two affected rows.
        func reload(_ tableView: NSTableView) {
            let indices = model.matchedIndices
            let revealed = model.revealedIndex

            if indices != lastMatchedIndices {
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

        func numberOfRows(in tableView: NSTableView) -> Int {
            model.matchedIndices.count
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

            guard row < model.matchedIndices.count else { return hostingView }
            let index = model.matchedIndices[row]
            let i = Int(index)
            let entry: Entry? = i < model.entries.count ? model.entries[i] : nil
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
