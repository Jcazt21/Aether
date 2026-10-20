import SwiftUI

struct Readout: View {
    enum Tone { case primary, secondary, tertiary, signal, fault }

    private let text: String
    private let tone: Tone

    init(_ text: String, tone: Tone = .secondary) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(verbatim: text)
            .font(.readout)
            .foregroundStyle(style)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var style: AnyShapeStyle {
        switch tone {
        case .primary: AnyShapeStyle(.primary)
        case .secondary: AnyShapeStyle(.secondary)
        case .tertiary: AnyShapeStyle(.tertiary)
        case .signal: AnyShapeStyle(Tokens.signal)
        case .fault: AnyShapeStyle(Tokens.fault)
        }
    }
}

struct SectionLabel: View {
    private let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        SectionLabel("Señal")
        Readout("FLAC · 24 bit · 44.1 kHz", tone: .primary)
        Readout("VERIFICADO · ee68…7a1f", tone: .signal)
        Readout("CRC frame 1 204 inválido", tone: .fault)
    }
    .padding()
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
