import AppKit
import SwiftUI

/// A binary run outside an `.app` bundle is never activated by
/// LaunchServices. Its window opens, and Terminal keeps keyboard focus.
/// These two calls take the focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct KeywiseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    /// `Window` makes this scene unique, so macOS offers no File > New
    /// Window for it and restores no duplicate. `WindowGroup` opened two at
    /// launch.
    ///
    /// One AppModel backs the app, since @State here is created once per
    /// process. Every extra window would therefore show the same profile and
    /// share this one's search text and revealed row. Two of them also run
    /// `.task { model.start() }` twice against one KeywiseStore, where one
    /// window's `store.close()` lands while the other is still opening.
    var body: some Scene {
        Window("Keywise", id: "main") {
            ContentView(model: model)
                .task { await model.start() }
        }
        .defaultSize(width: 640, height: 480)
    }
}
