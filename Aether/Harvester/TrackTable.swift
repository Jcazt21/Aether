import AetherCore
import AppKit
import Cosmos
import HiFiClient
import SwiftUI

struct TrackTable: View {
    let tracks: [TidalTrack]
    @Binding var selection: Set<Int>
    @Environment(HarvesterStore.self) private var store
    @Environment(PlayerModel.self) private var player

    /// A List with fixed-width columns instead of SwiftUI's `Table`: on macOS 27 `Table`'s AppKit coordinator
    /// updates row views of a torn-down screen and traps in AttributeGraph ("no subgraph") after a download.
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(tracks, selection: $selection) { track in
                row(track)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds()
            .environment(\.defaultMinListRowHeight, 34)
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

    private var header: some View {
        HStack(spacing: Tokens.Space.m) {
            Color.clear.frame(width: 22, height: 1)
            Color.clear.frame(width: 20, height: 1)
            Text("Título").frame(maxWidth: .infinity, alignment: .leading)
            Text("Artista").frame(width: 180, alignment: .leading)
            Text("Álbum").frame(width: 160, alignment: .leading)
            Text("Duración").frame(width: 64, alignment: .trailing)
            Text("Calidad").frame(width: 78, alignment: .leading)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.Space.l)
        .padding(.vertical, Tokens.Space.xs)
        .accessibilityHidden(true)
    }

    private func row(_ track: TidalTrack) -> some View {
        HStack(spacing: Tokens.Space.m) {
            Button {
                player.preview(track, client: store.currentClient)
            } label: {
                if player.isPreparingPreview && player.previewingTrackID == track.id {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: player.previewingTrackID == track.id && player.state == .playing ? "pause.fill" : "play.fill")
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 22)
            .accessibilityLabel("Preescuchar")

            // ZStack keeps the 20 pt column even when there is no icon (a frame on EmptyView collapses).
            ZStack { matchIcon(for: track) }.frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).lineLimit(1)
                if let version = track.version, !version.isEmpty {
                    Text(version).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.allArtistNames).lineLimit(1).frame(width: 180, alignment: .leading)
            Text(track.album?.title ?? "").foregroundStyle(.secondary).lineLimit(1).frame(width: 160, alignment: .leading)
            Readout(Duration.seconds(track.duration).formatted(.time(pattern: .minuteSecond)))
                .frame(width: 64, alignment: .trailing)
            QualityBadge(hiRes: track.supportsHiRes).frame(width: 78, alignment: .leading)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: Tokens.Space.l, bottom: 0, trailing: Tokens.Space.l))
        .tag(track.id)
    }

    @ViewBuilder private func matchIcon(for track: TidalTrack) -> some View {
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
}
