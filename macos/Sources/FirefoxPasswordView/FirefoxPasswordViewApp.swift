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

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.start() }
        }
        .defaultSize(width: 640, height: 480)
    }
}
