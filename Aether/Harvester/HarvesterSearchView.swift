import HiFiClient
import SwiftUI

struct HarvesterSearchView: View {
    @Environment(HarvesterStore.self) private var store
    @FocusState private var searchFocused: Bool

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
        .onAppear { searchFocused = true }
        .task(id: "\(store.searchScope.rawValue)|\(store.searchQuery)") {
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
            await store.search()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ScopeSwitcher(selection: $store.searchScope)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .automatic) {
                HStack(spacing: Tokens.Space.xs) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar en Tidal", text: $store.searchQuery)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .frame(width: 200)
                    if !store.searchQuery.isEmpty {
                        Button { store.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Borrar búsqueda")
                    }
                }
                .padding(.horizontal, Tokens.Space.m)
                .accessibilityElement(children: .contain)
            }
            ToolbarSpacer(.fixed)
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
                                   description: Text("Escribe un artista, una pista o un álbum, o pega el link de una playlist de Spotify."))
        } else {
            switch store.searchScope {
            case .tracks:
                TrackTable(tracks: store.trackResults, selection: $store.selectedTrackIDs)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let playlist = store.playlistImport { PlaylistBanner(playlist: playlist) }
                    }
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

private struct PlaylistBanner: View {
    let playlist: PlaylistImport

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            Image(systemName: "music.note.list").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(playlist.name).lineLimit(1)
                Text(playlist.isDone
                     ? "\(playlist.matched) de \(playlist.total) encontradas en Tidal"
                     : "Buscando en Tidal… \(playlist.processed) de \(playlist.total)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !playlist.unmatched.isEmpty {
                Text("\(playlist.unmatched.count) sin encontrar")
                    .font(.callout).foregroundStyle(.secondary)
                    .help(playlist.unmatched.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, Tokens.Space.s)
        .background(.bar)
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

/// Two-segment control whose selection fills the whole segment. The system segmented picker draws a small inset
/// pill inside the toolbar's glass capsule, which reads as a second layer.
private struct ScopeSwitcher: View {
    @Binding var selection: SearchScope
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SearchScope.allCases, id: \.self) { scope in
                Button {
                    selection = scope
                } label: {
                    Text(scope.title)
                        .font(.body.weight(selection == scope ? .semibold : .regular))
                        .foregroundStyle(selection == scope ? .primary : .secondary)
                        .padding(.horizontal, Tokens.Space.l)
                        .frame(height: 30)
                        .background {
                            if selection == scope {
                                Capsule().fill(.white.opacity(0.14)).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == scope ? .isSelected : [])
            }
        }
        .padding(2)
        .glassEffect(.regular, in: .capsule)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ámbito")
    }
}
