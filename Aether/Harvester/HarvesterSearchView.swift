import HiFiClient
import SwiftUI

struct HarvesterSearchView: View {
    @Environment(HarvesterStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            content
                .navigationDestination(for: TidalAlbum.self) { AlbumTracksView(album: $0) }
        }
        .confirmationDialog(
            "\(store.pendingDuplicates?.count ?? 0) ya están en Master",
            isPresented: Binding(get: { store.pendingDuplicates != nil }, set: { if !$0 { store.resolvePendingDuplicates(includeDuplicates: false) } }),
            titleVisibility: .visible
        ) {
            Button("Omitirlas") { store.resolvePendingDuplicates(includeDuplicates: false) }
                .keyboardShortcut(.defaultAction)
            Button("Descargar de todos modos") { store.resolvePendingDuplicates(includeDuplicates: true) }
        } message: {
            Text("Coinciden por ISRC o por artista y título.")
        }
        .searchable(text: $store.searchQuery, placement: .toolbar, prompt: "Buscar en Tidal")
        .task(id: "\(store.searchScope.rawValue)|\(store.searchQuery)") {
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
            await store.search()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Ámbito", selection: $store.searchScope) {
                    ForEach(SearchScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            ToolbarItem { DestinationMenu() }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.enqueueSelection()
                } label: {
                    Label("Descargar", systemImage: "arrow.down.circle")
                }
                .disabled(store.selectedTrackIDs.isEmpty || store.searchScope != .tracks)
                .help("Descargar selección (⌘D)")
            }
        }
    }

    @ViewBuilder private var content: some View {
        @Bindable var store = store
        if let error = store.searchError {
            ContentUnavailableView("No se pudo buscar", systemImage: "bolt.horizontal.circle",
                                   description: Text(error))
        } else if store.searchQuery.count < 2 {
            ContentUnavailableView("Buscar en Tidal", systemImage: "magnifyingglass",
                                   description: Text("Escribe un artista, una pista o un álbum."))
        } else {
            switch store.searchScope {
            case .tracks:
                TrackTable(tracks: store.trackResults, selection: $store.selectedTrackIDs)
                    .overlay { if store.isSearching && store.trackResults.isEmpty { ProgressView().controlSize(.small) } }
            case .albums:
                List(store.albumResults) { album in
                    NavigationLink(value: album) { AlbumRow(album: album) }
                }
                .overlay { if store.isSearching && store.albumResults.isEmpty { ProgressView().controlSize(.small) } }
            }
        }
    }
}

private struct AlbumRow: View {
    let album: TidalAlbum

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(album.title).lineLimit(1)
                Text(album.primaryArtistName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Readout([album.year, album.numberOfTracks.map { "\($0) pistas" }].compactMap { $0 }.joined(separator: " · "))
            QualityBadge(hiRes: album.supportsHiRes)
        }
        .padding(.vertical, 2)
    }
}
