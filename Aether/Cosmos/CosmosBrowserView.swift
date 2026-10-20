import AppKit
import Cosmos
import QuickLook
import SwiftUI
import TagKit

struct CosmosBrowserView: View {
    @Environment(CosmosStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var store = store
        Table(of: Cosmos.LibraryItem.self, selection: $store.selection, sortOrder: $store.sortOrder) {
            TableColumn("Artista", value: \.displayArtist) { Text($0.displayArtist).lineLimit(1) }
                .width(min: 120, ideal: 180)
            TableColumn("Título", value: \.displayTitle) { Text($0.displayTitle).lineLimit(1) }
                .width(min: 160, ideal: 280)
            TableColumn("Género", value: \.genreValue) { Text($0.genreValue).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 70, ideal: 100)
            TableColumn("BPM", value: \.bpmValue) { Readout($0.bpmValue > 0 ? TrackTags.formatBPM($0.bpmValue) : "—") }
                .width(48)
            TableColumn("Key", value: \.keyValue) { Readout($0.keyValue.isEmpty ? "—" : $0.keyValue) }
                .width(44)
            TableColumn("Formato", value: \.format.sampleRate) { item in
                Readout(item.format.label, tone: item.format.isLossless ? .secondary : .fault)
            }
            .width(min: 80, ideal: 96)
            TableColumn("Duración", value: \.durationValue) {
                Readout(Duration.seconds($0.format.duration).formatted(.time(pattern: .minuteSecond)))
            }
            .width(60)
            TableColumn("Tamaño", value: \.fileSize) { Readout($0.fileSize.formatted(.byteCount(style: .file))) }
                .width(70)
            TableColumn("✓") { item in
                if item.isVerified {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Tokens.signal)
                        .help(item.verifiedStamp ?? "").accessibilityLabel("Verificado")
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
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(store.url(for:))) }
            MoveToMenu(items: items)
            Button("Renombrar desde tags…") { Task { store.renamePlan = await store.plannedRenames(for: items) } }
            Button("Verificar integridad") { Task { _ = await store.verify(items) } }
                .disabled(!items.contains { $0.format.codec == .flac })
            Divider()
            Button("Mover a la Papelera", role: .destructive) { Task { await store.trash(items, undoManager: undoManager) } }
        } primaryAction: { ids in
            // Double-click: reveal for now; plan 06 turns this into "play in Aether Core".
            NSWorkspace.shared.activateFileViewerSelecting(store.visible.filter { ids.contains($0.id) }.map(store.url(for:)))
        }
        .quickLookPreview($store.quickLookURL, in: store.visible.map(store.url(for:)))
        .sheet(item: Binding(get: { store.renamePlan.map(IdentifiedPlan.init) }, set: { store.renamePlan = $0?.moves })) {
            RenamePreviewSheet(plan: $0.moves)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.scope != .cosmosInbox {
                Label("Mover archivos ya importados en rekordbox rompe sus rutas. Clasifica antes de importar.",
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
                    .help("Mover a… (⇧⌘M)")
                Button {
                    Task { await store.trash(store.selectedItems, undoManager: undoManager) }
                } label: {
                    Label("Mover a la Papelera", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.selection.isEmpty)
                .help("Mover a la Papelera (⌘⌫)")
            }
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Buscar en Master")
        .navigationTitle(title)
        .navigationSubtitle("\(store.visible.count) pistas")
        .overlay {
            if store.visible.isEmpty && !store.isScanning {
                ContentUnavailableView("Nada aquí", systemImage: "folder", description: Text("No hay pistas en esta vista."))
            }
        }
    }

    private var title: String {
        switch store.scope {
        case .cosmosFolder(let name): name
        case .cosmosInbox: "Por clasificar"
        case .cosmosReview(let filter): filter.title
        default: "Master"
        }
    }
}

private struct IdentifiedPlan: Identifiable {
    let moves: [FileMove]
    var id: Int { moves.map(\.from.path).hashValue }
}
