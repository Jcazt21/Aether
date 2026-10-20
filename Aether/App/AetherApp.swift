import SwiftUI

@main
struct AetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // Single library window, like Music: Harvester's queue and Cosmos' index are app-wide singletons,
        // so additional windows would only mirror the same state.
        Window("Aether", id: "main") {
            RootView()
                .environment(model)
                .environment(model.preferences)
                .environment(model.harvester)
                .environment(model.cosmos)
                .environment(model.player)
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    appDelegate.onTerminate = { [player = model.player] in player.shutdown() }
                    appDelegate.dockMenu.player = model.player
                }
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands { AetherCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model.preferences)
                .preferredColorScheme(.dark)
        }
    }
}
