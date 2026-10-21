import SwiftUI

struct StatusGlyph: View {
    enum Status: Equatable { case queued, working, verifying, verified, failed, cancelled }

    private let status: Status

    init(_ status: Status) { self.status = status }

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 16)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch status {
        case .queued: "circle.dotted"
        case .working: "arrow.down.circle"
        case .verifying: "checkmark.shield"
        case .verified: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var color: AnyShapeStyle {
        switch status {
        case .verified: AnyShapeStyle(Tokens.signal)
        case .failed: AnyShapeStyle(Tokens.fault)
        case .working, .verifying: AnyShapeStyle(.tint)
        case .queued, .cancelled: AnyShapeStyle(.tertiary)
        }
    }

    private var label: Text {
        switch status {
        case .queued: Text("Queued")
        case .working: Text("Downloading")
        case .verifying: Text("Verifying")
        case .verified: Text("Verified")
        case .failed: Text("Failed")
        case .cancelled: Text("Cancelled")
        }
    }
}
