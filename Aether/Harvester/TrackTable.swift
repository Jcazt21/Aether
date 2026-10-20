import AppKit
import Cosmos
import HiFiClient
import SwiftUI

struct TrackTable: View {
    let tracks: [TidalTrack]
    @Binding var selection: Set<Int>
    @Environment(HarvesterStore.self) private var store

    var body: some View {
        Table(tracks, selection: $selection) {
            TableColumn("") { track in
                switch store.masterMatch(for: track) {
                case .exact(let item):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Tokens.signal)
                        .help("Ya en Master: \(item.relativePath)")
                        .accessibilityLabel("Ya en Master")
                case .similar(let item):
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
                        .help("Parecida en Master: \(item.relativePath)")
                        .accessibilityLabel("Versión parecida en Master")
                case nil:
                    EmptyView()
                }
            }
            .width(20)
            TableColumn("Título") { track in
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).lineLimit(1)
                    if let version = track.version, !version.isEmpty {
                        Text(version).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 200, ideal: 320)
            TableColumn("Artista") { Text($0.allArtistNames).lineLimit(1) }
                .width(min: 120, ideal: 200)
            TableColumn("Álbum") { Text($0.album?.title ?? "").foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 100, ideal: 180)
            TableColumn("Duración") { track in
                Readout(Duration.seconds(track.duration).formatted(.time(pattern: .minuteSecond)))
            }
            .width(64)
            TableColumn("Calidad") { QualityBadge(hiRes: $0.supportsHiRes) }
                .width(78)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            Button("Descargar \(ids.count == 1 ? "pista" : "\(ids.count) pistas")") {
                store.requestEnqueue(tracks.filter { ids.contains($0.id) })
            }
            .disabled(ids.isEmpty)
            Divider()
            Button("Copiar enlace de Tidal") {
                let links = tracks.filter { ids.contains($0.id) }.map { "https://tidal.com/track/\($0.id)" }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
            }
        } primaryAction: { ids in
            store.requestEnqueue(tracks.filter { ids.contains($0.id) })
        }
    }
}
