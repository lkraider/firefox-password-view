import AppKit
import SwiftUI

/// This binary has no `.app` bundle, so LaunchServices never activates it:
/// without this, the window opens but Terminal keeps keyboard focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct FirefoxPasswordViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    /// `Window` rather than `WindowGroup`: this scene is unique, so macOS
    /// offers no File > New Window and restores no duplicate of it.
    ///
    /// One AppModel backs the app, since @State here is created once per
    /// process. Every extra window would therefore show the same profile and
    /// share this one's search text and revealed row. Two of them also run
    /// `.task { model.start() }` twice against one FFPWStore, where one
    /// window's `store.close()` lands while the other is still opening.
    var body: some Scene {
        Window("Firefox Passwords", id: "main") {
            ContentView(model: model)
                .task { await model.start() }
        }
        .defaultSize(width: 640, height: 480)
    }
}
