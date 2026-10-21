import AetherCore
import SwiftUI

struct SignalPopover: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            SectionLabel("Signal path")
            if let signal = player.signal, let now = player.current {
                row("Source", now.formatLabel)
                row("Output", "\(signal.deviceName) · \(Int(signal.deviceRate)) Hz")
                row("Gain", "0.0 dB (volume set in the system)")
                Readout(signal.isBitPerfect ? "BIT-PERFECT" : "RESAMPLED \(Int(signal.sourceRate)) → \(Int(signal.deviceRate)) Hz",
                        tone: signal.isBitPerfect ? .signal : .fault)
            }
            SectionLabel("Level")
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: player.state != .playing)) { _ in
                LevelMeter(levels: player.engine.meter.current)
            }
        }
        .padding(Tokens.Space.l)
        .frame(width: 300)
        .onAppear { player.meteringVisible = true }
        .onDisappear { player.meteringVisible = false }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent { Readout(value, tone: .primary) } label: { Text(label).foregroundStyle(.secondary) }
    }
}

struct LevelMeter: View {
    let levels: MeterTap.Levels

    var body: some View {
        VStack(spacing: Tokens.Space.xs) {
            ForEach(levels.peak.indices, id: \.self) { ch in
                let db = 20 * log10(max(Double(levels.peak[ch]), 0.000_01))
                let fraction = min(max((db + 60) / 60, 0), 1)
                HStack(spacing: Tokens.Space.s) {
                    Readout(ch == 0 ? "L" : "R", tone: .tertiary)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tokens.hairline)
                        Capsule().fill(db > -0.1 ? AnyShapeStyle(Tokens.fault) : AnyShapeStyle(Tokens.signal))
                            .scaleEffect(x: fraction, y: 1, anchor: .leading)
                    }
                    .frame(height: 3)
                    Readout(db <= -60 ? "-∞" : String(format: "%.1f", db)).frame(width: 40, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level meter")
    }
}
