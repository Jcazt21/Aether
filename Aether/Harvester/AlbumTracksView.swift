import HiFiClient
import SwiftUI

struct AlbumTracksView: View {
    let album: TidalAlbum
    @Environment(HarvesterStore.self) private var store
    @State private var tracks: [TidalTrack] = []
    @State private var selection: Set<Int> = []

    var body: some View {
        TrackTable(tracks: tracks, selection: $selection)
            .navigationTitle(album.title)
            .navigationSubtitle([album.primaryArtistName, album.year].compactMap { $0 }.joined(separator: " · "))
            .task { tracks = await store.loadAlbum(album) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.requestEnqueue(selection.isEmpty ? tracks : tracks.filter { selection.contains($0.id) })
                    } label: {
                        Label(selection.isEmpty ? "Descargar álbum" : "Descargar selección", systemImage: "arrow.down.circle")
                    }
                    .disabled(tracks.isEmpty)
                }
            }
    }
}
