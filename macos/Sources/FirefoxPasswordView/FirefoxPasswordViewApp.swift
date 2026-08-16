import SwiftUI

@main
struct FirefoxPasswordViewApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.start() }
        }
        .defaultSize(width: 640, height: 480)
    }
}
