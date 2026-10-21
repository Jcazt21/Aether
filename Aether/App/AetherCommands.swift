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
            Button("Search Tidal") { model.route = .harvesterSearch }
                .keyboardShortcut("1")
            Button("Hermes Queue") { model.route = .harvesterQueue }
                .keyboardShortcut("2")
            Button("Master") { model.route = .cosmosAll }
                .keyboardShortcut("3")
        }
        CommandMenu("Hermes") {
            Button("Download Selection") { model.harvester.enqueueSelection() }
                .keyboardShortcut("d")
                .disabled(model.harvester.selectedTrackIDs.isEmpty)
            Button("Retry Failed") { model.harvester.retryFailed() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.harvester.failedCount == 0)
            Divider()
            Button("Clear Finished") { model.harvester.clearFinished() }
        }
        CommandMenu("Cosmos") {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(model.cosmos.selectedItems.map(model.cosmos.url(for:)))
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.cosmos.selection.isEmpty)
            Button("Quick Look") { model.cosmos.quickLookURL = model.cosmos.selectedItems.first.map(model.cosmos.url(for:)) }
                .keyboardShortcut("y")
                .disabled(model.cosmos.selection.isEmpty)
            Button("Rename from Tags…") {
                Task { model.cosmos.renamePlan = await model.cosmos.plannedRenames(for: model.cosmos.selectedItems) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model.cosmos.selection.isEmpty)
            Button("Verify Integrity") { Task { _ = await model.cosmos.verify(model.cosmos.selectedItems) } }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(model.cosmos.selection.isEmpty)
            Divider()
            Button("Rescan Master") { Task { await model.cosmos.rescan() } }
        }
        CommandMenu("Control") {
            Button(model.player.state == .playing ? "Pause" : "Play") { model.player.toggle() }
                .disabled(model.player.current == nil && model.player.queue.current == nil)
            Button("Next") { model.player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { model.player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Skip Forward 10 s") { model.player.skip(by: 10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Skip Back 10 s") { model.player.skip(by: -10) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        }
    }
}
