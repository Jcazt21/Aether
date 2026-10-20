import AetherCore
import SwiftUI

/// Canvas waveform; the played portion is redrawn only while playing (TimelineView is paused otherwise).
struct WaveformScrubber: View {
    let peaks: [Float]
    @Environment(PlayerModel.self) private var player
    @State private var width: CGFloat = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: player.state != .playing)) { _ in
            let duration = player.duration
            let progress = duration > 0 ? player.currentTime / duration : 0
            HStack(spacing: Tokens.Space.s) {
                Readout(format(player.currentTime))
                Canvas { context, size in
                    let columns = max(Int(size.width / 2), 1)
                    let playedX = size.width * progress
                    for column in 0..<columns {
                        let x = CGFloat(column) * 2
                        let value = peaks.isEmpty ? 0.08 : CGFloat(sample(column, of: columns))
                        let height = max(size.height * value, 1)
                        let rect = CGRect(x: x, y: (size.height - height) / 2, width: 1, height: height)
                        context.fill(Path(rect), with: .color(x <= playedX ? .primary : .secondary.opacity(0.35)))
                    }
                }
                .frame(height: 26)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { seek($0.location.x) })
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                Readout("-" + format(max(duration - player.currentTime, 0)))
            }
            .accessibilityElement()
            .accessibilityLabel("Posición")
            .accessibilityValue("\(format(player.currentTime)) de \(format(duration))")
            .accessibilityAdjustableAction { direction in
                player.skip(by: direction == .increment ? 10 : -10)
            }
        }
    }

    private func seek(_ x: CGFloat) { player.seek(toFraction: Double(x / max(width, 1))) }

    private func sample(_ column: Int, of columns: Int) -> Float {
        let start = column * peaks.count / columns
        let end = max((column + 1) * peaks.count / columns, start + 1)
        return peaks[start..<min(end, peaks.count)].max() ?? 0
    }

    private func format(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}
