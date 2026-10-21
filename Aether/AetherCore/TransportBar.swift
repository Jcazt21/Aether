import AetherCore
import SwiftUI

struct TransportBar: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var displayScale
    @State private var showSignal = false
    @State private var scrubbing = false

    var body: some View {
        if let now = player.current {
            GlassEffectContainer(spacing: Tokens.Space.s) {
                HStack(spacing: Tokens.Space.l) {
                    HStack(spacing: Tokens.Space.xs) {
                        transportButton("backward.fill", "Anterior") { player.previous() }
                        transportButton(player.state == .playing ? "pause.fill" : "play.fill",
                                        player.state == .playing ? "Pausa" : "Reproducir", large: true) { player.toggle() }
                        transportButton("forward.fill", "Siguiente") { player.next() }
                    }

                    ZStack {
                        HStack(spacing: Tokens.Space.m) {
                            artwork(now)
                            VStack(alignment: .leading, spacing: 3) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(now.title).font(.callout.weight(.semibold)).lineLimit(1)
                                    Text(now.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                ProgressLine(expanded: false)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(scrubbing ? 0 : 1)

                        ProgressLine(expanded: true)
                            .opacity(scrubbing ? 1 : 0)
                            .allowsHitTesting(scrubbing)
                    }
                    .frame(minWidth: 220, maxWidth: .infinity)
                    .contentShape(.rect)
                    .onHover { scrubbing = $0 }
                    .animation(.easeOut(duration: 0.15), value: scrubbing)

                    Button { showSignal.toggle() } label: {
                        Readout(player.signal.map { $0.isBitPerfect ? "\(now.formatLabel) · BIT-PERFECT" : now.formatLabel } ?? now.formatLabel,
                                tone: player.signal?.isBitPerfect == true ? .signal : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Cadena de señal")
                    .popover(isPresented: $showSignal, arrowEdge: .top) { SignalPopover() }
                }
                .padding(.horizontal, Tokens.Space.l)
                .padding(.vertical, Tokens.Space.s)
                .background {
                    if reduceTransparency { Capsule().fill(Tokens.surface).overlay(Capsule().strokeBorder(Tokens.hairline)) }
                }
                .glassEffect(reduceTransparency ? .identity : .regular, in: .capsule)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, Tokens.Space.l)
            .padding(.bottom, Tokens.Space.m)
            .frame(maxWidth: .infinity)
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
        .frame(width: 36, height: 36)
        .clipShape(.rect(cornerRadius: 4))
    }

    private func transportButton(_ symbol: String, _ label: LocalizedStringKey, large: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(large ? .title2 : .body).frame(width: large ? 34 : 28, height: 28)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(label))
    }
}

/// Seekable progress line. Collapsed it is a hairline under the title; expanded (on hover) it shows elapsed/remaining time.
private struct ProgressLine: View {
    let expanded: Bool
    @Environment(PlayerModel.self) private var player
    @State private var width: CGFloat = 1

    var body: some View {
        // Accessibility sits outside the TimelineView: rebuilding the a11y tree at 15 fps while views
        // are being swapped trips SwiftUI's "no subgraph" precondition.
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: player.state != .playing)) { _ in
            let duration = player.duration
            let time = player.currentTime
            let progress = duration > 0 ? min(time / duration, 1) : 0
            HStack(spacing: Tokens.Space.m) {
                if expanded { Readout(format(time)).frame(minWidth: 36, alignment: .trailing) }
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.3))
                    Capsule().fill(.primary).frame(width: width * progress)
                }
                .frame(height: expanded ? 6 : 3)
                .frame(height: 14)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { player.seek(toFraction: Double($0.location.x / max(width, 1))) })
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                if expanded { Readout("-" + format(max(duration - time, 0))).frame(minWidth: 40, alignment: .leading) }
            }
            .accessibilityHidden(true)
        }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { player.duration > 0 ? player.currentTime / player.duration : 0 },
                                  set: { player.seek(toFraction: $0) }))
                .accessibilityLabel("Posición")
                .accessibilityHidden(expanded)
        }
    }

    private func format(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}
