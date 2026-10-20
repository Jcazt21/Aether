import Harvester
import SwiftUI

struct HarvesterQueueView: View {
    @Environment(HarvesterStore.self) private var store
    @State private var selection: JobModel.ID?

    var body: some View {
        Group {
            if store.jobs.isEmpty {
                ContentUnavailableView("Cola vacía", systemImage: "arrow.down.circle",
                                       description: Text("Busca en Tidal y pulsa ⌘D para descargar."))
            } else {
                List(store.jobs, selection: $selection) { job in
                    JobRow(job: job)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Cola")
        .navigationSubtitle(store.activeCount > 0 ? "\(store.activeCount) activas" : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.retryFailed() } label: { Label("Reintentar fallidas", systemImage: "arrow.clockwise") }
                    .disabled(store.failedCount == 0)
                Button { store.clearFinished() } label: { Label("Limpiar terminadas", systemImage: "checkmark.circle.badge.xmark") }
                    .disabled(!store.jobs.contains { $0.phase.isTerminal })
            }
        }
        .onKeyPress(.delete) {
            guard let id = selection else { return .ignored }
            store.cancel(id)
            return .handled
        }
    }
}
