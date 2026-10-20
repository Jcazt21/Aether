import SwiftUI

struct QualityBadge: View {
    let hiRes: Bool

    var body: some View {
        Text(hiRes ? "HI-RES" : "LOSSLESS")
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .tracking(0.4)
            .foregroundStyle(hiRes ? AnyShapeStyle(Tokens.signal) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Tokens.hairline))
            .accessibilityLabel(hiRes ? "Alta resolución" : "Sin pérdida")
    }
}
