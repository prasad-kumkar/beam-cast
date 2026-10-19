import SwiftUI

@main
struct BeamApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 560)
                .onOpenURL { model.open($0) }
        }
        .handlesExternalEvents(matching: ["*"])
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 620)
        .windowResizability(.contentMinSize)

        Settings {
            EmptyView()
        }
    }
}
