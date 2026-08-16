import AppKit

/// Copies a password so clipboard managers leave it out of their history.
/// nspasteboard.org defines `org.nspasteboard.ConcealedType` as the marker
/// for exactly this, and 1Password and Bitwarden set it the same way.
/// `TransientType` is not also set: nspasteboard.org calls over-marking out
/// as a mistake, not a stronger guarantee.
@MainActor
enum ClipboardWriter {
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static var pendingClear: DispatchWorkItem?

    static func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        pasteboard.setString("", forType: concealedType)

        let changeCount = pasteboard.changeCount
        pendingClear?.cancel()
        let clear = DispatchWorkItem {
            // Only clear if nothing else has been copied since: the point is
            // wiping this password, not any later, unrelated clipboard use.
            if NSPasteboard.general.changeCount == changeCount {
                NSPasteboard.general.clearContents()
            }
        }
        pendingClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: clear)
    }
}
