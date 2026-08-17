import AppKit

/// Copies a password so clipboard managers leave it out of their history.
/// nspasteboard.org defines `org.nspasteboard.ConcealedType` for this, and
/// 1Password and Bitwarden set the same marker. `TransientType` stays
/// unset. nspasteboard.org documents it for content a manager should ignore
/// completely, and a password the user asked to copy is not that.
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
            // An unchanged changeCount means the password is still on the
            // pasteboard. Any later copy bumps it, and that value stays.
            if NSPasteboard.general.changeCount == changeCount {
                NSPasteboard.general.clearContents()
            }
        }
        pendingClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: clear)
    }
}
