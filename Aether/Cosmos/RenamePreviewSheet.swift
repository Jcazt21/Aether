import Cosmos
import SwiftUI

struct RenamePreviewSheet: View {
    let plan: [FileMove]
    @Environment(CosmosStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text("Rename from Tags").font(.headline)
            Text("Format: Artist - Title. Files without a title or artist are left alone.")
                .font(.callout).foregroundStyle(.secondary)
            List(plan, id: \.from) { move in
                VStack(alignment: .leading, spacing: 2) {
                    Readout(move.from.lastPathComponent, tone: .tertiary)
                    Readout("→ \(move.to.lastPathComponent)", tone: .primary)
                }
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename \(plan.count)") {
                    Task { await store.applyRenames(plan, undoManager: undoManager); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty)
            }
        }
        .padding(Tokens.Space.xl)
        .frame(width: 560)
    }
}
