import SwiftUI

/// Two-pass hairline: transfer fill (accent) then verification fill (signal) over the same 2 pt track.
/// Only `scaleEffect(x:)` is animated — a transform, no layout pass per update.
struct HairlineProgress: View {
    enum Stage: Equatable { case idle, transferring, verifying, verified, failed }

    private let transfer: Double
    private let verify: Double
    private let stage: Stage

    init(transfer: Double, verify: Double, stage: Stage) {
        self.transfer = transfer.clamped
        self.verify = verify.clamped
        self.stage = stage
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(stage == .failed ? AnyShapeStyle(Tokens.fault) : AnyShapeStyle(Tokens.hairline))
            Capsule()
                .fill(.tint)
                .opacity(stage == .verified || stage == .failed ? 0 : 0.85)
                .scaleEffect(x: transfer, y: 1, anchor: .leading)
                .animation(Tokens.Motion.progress, value: transfer)
            Capsule()
                .fill(Tokens.signal)
                .scaleEffect(x: stage == .verified ? 1 : verify, y: 1, anchor: .leading)
                .animation(Tokens.Motion.progress, value: verify)
        }
        .frame(height: 2)
        .animation(Tokens.Motion.state, value: stage)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: Text {
        switch stage {
        case .idle: Text("Queued")
        case .transferring: Text("Downloading \(Int(transfer * 100)) percent")
        case .verifying: Text("Verifying \(Int(verify * 100)) percent")
        case .verified: Text("Verified")
        case .failed: Text("Failed")
        }
    }
}

private extension Double {
    var clamped: Double { Swift.min(Swift.max(self, 0), 1) }
}

#Preview {
    VStack(spacing: 16) {
        HairlineProgress(transfer: 0.0, verify: 0, stage: .idle)
        HairlineProgress(transfer: 0.42, verify: 0, stage: .transferring)
        HairlineProgress(transfer: 1, verify: 0.6, stage: .verifying)
        HairlineProgress(transfer: 1, verify: 1, stage: .verified)
        HairlineProgress(transfer: 0.7, verify: 0, stage: .failed)
    }
    .padding()
    .frame(width: 420)
    .background(Tokens.canvas)
    .preferredColorScheme(.dark)
}
