import Harvester
import SwiftUI

struct HarvesterQueueView: View {
    @Environment(HarvesterStore.self) private var store
    @State private var selection: JobModel.ID?

    var body: some View {
        Group {
            if store.jobs.isEmpty {
                ContentUnavailableView("Queue Empty", systemImage: "arrow.down.circle",
                                       description: Text("Search Tidal and press ⌘D to download."))
            } else {
                List(store.jobs, selection: $selection) { job in
                    JobRow(job: job)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Queue")
        .navigationSubtitle(store.activeCount > 0 ? "\(store.activeCount) active" : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.retryFailed() } label: { Label("Retry Failed", systemImage: "arrow.clockwise") }
                    .disabled(store.failedCount == 0)
                Button { store.clearFinished() } label: { Label("Clear Finished", systemImage: "checkmark.circle.badge.xmark") }
                    .disabled(!store.hasFinishedJobs)
            }
        }
        .onKeyPress(.delete) {
            guard let id = selection else { return .ignored }
            store.cancel(id)
            return .handled
        }
    }
}
