import SwiftUI

struct AetherCommands: Commands {
    let model: AppModel

    var body: some Commands {
        SidebarCommands()
        InspectorCommands()
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Buscar en Tidal") { model.route = .harvesterSearch }
                .keyboardShortcut("1")
            Button("Cola de Harvester") { model.route = .harvesterQueue }
                .keyboardShortcut("2")
            Button("Master") { model.route = .cosmosAll }
                .keyboardShortcut("3")
        }
    }
}
