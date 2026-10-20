import AetherCore
import SwiftUI

struct TransportBar: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var displayScale
    @State private var showSignal = false

    var body: some View {
        if let now = player.current {
            GlassEffectContainer(spacing: Tokens.Space.s) {
                HStack(spacing: Tokens.Space.m) {
                    artwork(now)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(now.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(now.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: 180, alignment: .leading)

                    HStack(spacing: Tokens.Space.xs) {
                        transportButton("backward.fill", "Anterior") { player.previous() }
                        transportButton(player.state == .playing ? "pause.fill" : "play.fill",
                                        player.state == .playing ? "Pausa" : "Reproducir") { player.toggle() }
                        transportButton("forward.fill", "Siguiente") { player.next() }
                    }

                    WaveformScrubber(peaks: player.waveform)
                        .frame(minWidth: 200)

                    Button { showSignal.toggle() } label: {
                        Readout(player.signal.map { $0.isBitPerfect ? "\(now.formatLabel) · BIT-PERFECT" : now.formatLabel } ?? now.formatLabel,
                                tone: player.signal?.isBitPerfect == true ? .signal : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Cadena de señal")
                    .popover(isPresented: $showSignal, arrowEdge: .top) { SignalPopover() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, Tokens.Space.s)
                .background {
                    if reduceTransparency { Capsule().fill(Tokens.surface).overlay(Capsule().strokeBorder(Tokens.hairline)) }
                }
                .glassEffect(reduceTransparency ? .identity : .regular, in: .capsule)
            }
            .padding(.horizontal, Tokens.Space.l)
            .padding(.bottom, Tokens.Space.m)
        }
    }

    private func artwork(_ now: NowPlaying) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Tokens.surface)
            if let cg = now.artwork {
                Image(decorative: cg, scale: displayScale).resizable().scaledToFill()
            } else {
                Image(systemName: "waveform").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(.rect(cornerRadius: 4))
    }

    private func transportButton(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body).frame(width: 28, height: 24)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(label))
    }
}
