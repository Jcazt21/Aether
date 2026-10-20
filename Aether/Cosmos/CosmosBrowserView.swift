import Cosmos
import SwiftUI
import TagKit

struct CosmosBrowserView: View {
    @Environment(CosmosStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Table(of: LibraryItem.self, selection: $store.selection, sortOrder: $store.sortOrder) {
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
