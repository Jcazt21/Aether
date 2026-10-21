import AppKit
import Cosmos
import QuickLook
import SwiftUI
import TagKit

struct CosmosBrowserView: View {
    @Environment(CosmosStore.self) private var store
    @Environment(PlayerModel.self) private var player
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var store = store
        Table(of: Cosmos.LibraryItem.self, selection: $store.selection, sortOrder: $store.sortOrder) {
            TableColumn("Artist", value: \.displayArtist) { Text($0.displayArtist).lineLimit(1) }
                .width(min: 120, ideal: 180)
            TableColumn("Title", value: \.displayTitle) { Text($0.displayTitle).lineLimit(1) }
                .width(min: 160, ideal: 280)
            TableColumn("Genre", value: \.genreValue) { Text($0.genreValue).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 70, ideal: 100)
            TableColumn("BPM", value: \.bpmValue) { Readout($0.bpmValue > 0 ? TrackTags.formatBPM($0.bpmValue) : "—") }
                .width(48)
            TableColumn("Key", value: \.keyValue) { Readout($0.keyValue.isEmpty ? "—" : $0.keyValue) }
                .width(44)
            TableColumn("Format", value: \.format.sampleRate) { item in
                Readout(item.format.label, tone: item.format.isLossless ? .secondary : .fault)
            }
            .width(min: 80, ideal: 96)
            TableColumn("Duration", value: \.durationValue) {
                Readout(Duration.seconds($0.format.duration).formatted(.time(pattern: .minuteSecond)))
            }
            .width(60)
            TableColumn("Added", value: \.addedValue) {
                Readout($0.addedValue.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
            }
            .width(min: 90, ideal: 116)
            TableColumn("Size", value: \.fileSize) { Readout($0.fileSize.formatted(.byteCount(style: .file))) }
                .width(70)
            TableColumn("✓") { item in
                if item.isVerified {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Tokens.signal)
                        .help(item.verifiedStamp ?? "").accessibilityLabel("Verified")
                }
            }
            .width(24)
        } rows: {
            ForEach(store.visible) { item in
                TableRow(item).draggable(store.url(for: item))
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let items = store.visible.filter { ids.contains($0.id) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(store.url(for:))) }
            MoveToMenu(items: items)
            Button("Rename from Tags…") { Task { store.renamePlan = await store.plannedRenames(for: items) } }
            Button("Verify Integrity") { Task { _ = await store.verify(items) } }
                .disabled(!items.contains { $0.format.codec == .flac })
            Divider()
            Button("Move to Trash", role: .destructive) { Task { await store.trash(items, undoManager: undoManager) } }
        } primaryAction: { ids in
            let urls = store.visible.map(store.url(for:))
            guard let first = store.visible.firstIndex(where: { ids.contains($0.id) }) else { return }
            player.play(urls: urls, startAt: first)
        }
        .quickLookPreview($store.quickLookURL, in: store.visible.map(store.url(for:)))
        .sheet(item: Binding(get: { store.renamePlan.map(IdentifiedPlan.init) }, set: { store.renamePlan = $0?.moves })) {
            RenamePreviewSheet(plan: $0.moves)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.scope != .cosmosInbox {
                Label("Moving files already imported into rekordbox breaks their paths. Sort before importing.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.Space.l).padding(.vertical, Tokens.Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                MoveToMenu(items: store.selectedItems)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .help("Move to… (⇧⌘M)")
                Button {
                    Task { await store.trash(store.selectedItems, undoManager: undoManager) }
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.selection.isEmpty)
                .help("Move to Trash (⌘⌫)")
            }
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search Master")
        .navigationTitle(title)
        .navigationSubtitle("\(store.visible.count) tracks")
        .overlay {
            if store.visible.isEmpty && !store.isScanning {
                ContentUnavailableView("Nothing Here", systemImage: "folder", description: Text("There are no tracks in this view."))
            }
        }
    }

    private var title: String {
        switch store.scope {
        case .cosmosFolder(let name): name
        case .cosmosInbox: "Inbox"
        case .cosmosReview(let filter): filter.title
        default: "Master"
        }
    }
}

private struct IdentifiedPlan: Identifiable {
    let moves: [FileMove]
    var id: Int { moves.map(\.from.path).hashValue }
}
