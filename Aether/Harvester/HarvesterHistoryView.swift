import AppKit
import FlacKit
import Harvester
import SwiftUI

struct HarvesterHistoryView: View {
    @Environment(HarvesterStore.self) private var store
    @Environment(PlayerModel.self) private var player
    @State private var selection: Set<HistoryEntry.ID> = []

    var body: some View {
        Table(store.history, selection: $selection) {
            TableColumn("Title") { Text($0.title).lineLimit(1) }.width(min: 180, ideal: 280)
            TableColumn("Artist") { Text($0.artist).lineLimit(1) }.width(min: 120, ideal: 180)
            TableColumn("Format") { Readout($0.format.label) }.width(96)
            TableColumn("MD5") { Readout($0.report.shortMD5, tone: .signal) }.width(90)
            TableColumn("Folder") { Text($0.fileURL.deletingLastPathComponent().lastPathComponent).foregroundStyle(.secondary) }
                .width(min: 90, ideal: 120)
            TableColumn("Date") { Readout($0.finishedAt.formatted(date: .abbreviated, time: .shortened)) }.width(130)
        }
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            let entries = store.history.filter { ids.contains($0.id) }
            Button("Play") {
                player.play(urls: entries.map(\.fileURL), startAt: 0)
            }
            .disabled(entries.isEmpty)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(entries.map(\.fileURL))
            }
        }
        .navigationTitle("History")
        .overlay {
            if store.history.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock",
                                       description: Text("Verified downloads will appear here."))
            }
        }
    }
}
