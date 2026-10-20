import AppKit
import FlacKit
import Harvester
import SwiftUI

struct JobRow: View {
    let job: JobModel
    @Environment(HarvesterStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            HStack(spacing: Tokens.Space.m) {
                StatusGlyph(job.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.title).lineLimit(1)
                    Text(job.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: Tokens.Space.l)
                Readout(job.readout, tone: job.readoutTone)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
            HairlineProgress(transfer: job.transferFraction, verify: job.verifyFraction, stage: job.stage)
        }
        .padding(.vertical, Tokens.Space.s)
        .contentShape(.rect)
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var menu: some View {
        switch job.phase {
        case .verified(let result):
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.fileURL]) }
            Button("Copiar MD5") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.report.md5Actual ?? "", forType: .string)
            }
        case .failed:
            Button("Reintentar") { store.retryFailed() }
        case .cancelled:
            EmptyView()
        default:
            Button("Cancelar") { store.cancel(job.id) }
        }
    }
}
