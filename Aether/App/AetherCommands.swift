import AetherCore
import AppKit
import Cosmos
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
        CommandMenu("Cosmos") {
            Button("Mostrar en Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(model.cosmos.selectedItems.map(model.cosmos.url(for:)))
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.cosmos.selection.isEmpty)
            Button("Quick Look") { model.cosmos.quickLookURL = model.cosmos.selectedItems.first.map(model.cosmos.url(for:)) }
                .keyboardShortcut("y")
                .disabled(model.cosmos.selection.isEmpty)
            Button("Renombrar desde tags…") {
                Task { model.cosmos.renamePlan = await model.cosmos.plannedRenames(for: model.cosmos.selectedItems) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model.cosmos.selection.isEmpty)
            Button("Verificar integridad") { Task { _ = await model.cosmos.verify(model.cosmos.selectedItems) } }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(model.cosmos.selection.isEmpty)
            Divider()
            Button("Re-escanear Master") { Task { await model.cosmos.rescan() } }
        }
        CommandMenu("Control") {
            Button(model.player.state == .playing ? "Pausa" : "Reproducir") { model.player.toggle() }
                .disabled(model.player.current == nil && model.player.queue.current == nil)
            Button("Siguiente") { model.player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Anterior") { model.player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Avanzar 10 s") { model.player.skip(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Retroceder 10 s") { model.player.skip(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        }
    }
}
