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
        CommandMenu("Harvester") {
            Button("Descargar selección") { model.harvester.enqueueSelection() }
                .keyboardShortcut("d")
                .disabled(model.harvester.selectedTrackIDs.isEmpty)
            Button("Reintentar fallidas") { model.harvester.retryFailed() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.harvester.failedCount == 0)
            Divider()
            Button("Limpiar terminadas") { model.harvester.clearFinished() }
        }
    }
}
