import SwiftUI

struct SidebarView: View {
    @Binding var route: Route
    @Environment(HarvesterStore.self) private var harvester
    @Environment(CosmosStore.self) private var cosmos
    @Environment(Preferences.self) private var preferences
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        List(selection: Binding<Route?>(get: { route }, set: { if let new = $0 { route = new } })) {
            Section("Harvester") {
                Label("Buscar", systemImage: "magnifyingglass").tag(Route.harvesterSearch)
                Label("Cola", systemImage: "arrow.down.circle").tag(Route.harvesterQueue)
                    .badge(harvester.activeCount)
                Label("Historial", systemImage: "clock").tag(Route.harvesterHistory)
            }
            Section("Cosmos") {
                Label("Master", systemImage: "folder").tag(Route.cosmosAll)
                Label("Por clasificar", systemImage: "tray").tag(Route.cosmosInbox)
                    .badge(cosmos.inboxCount)
                    .dropDestination(for: URL.self) { urls, _ in
                        Task { await cosmos.moveURLs(urls, toFolder: preferences.inboxFolderName, undoManager: undoManager) }
                        return true
                    }
                ForEach(cosmos.folders.filter { $0.name != preferences.inboxFolderName }) { folder in
                    Label(folder.name, systemImage: "folder")
                        .tag(Route.cosmosFolder(folder.name))
                        .dropDestination(for: URL.self) { urls, _ in
                            Task { await cosmos.moveURLs(urls, toFolder: folder.name, undoManager: undoManager) }
                            return true
                        }
                }
            }
            Section("Revisar") {
                ForEach(ReviewFilter.allCases, id: \.self) { filter in
                    Label(filter.title, systemImage: filter.symbol)
                        .tag(Route.cosmosReview(filter))
                        .badge(count(for: filter))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func count(for filter: ReviewFilter) -> Int {
        switch filter {
        case .untagged: cosmos.untaggedCount
        case .duplicates: cosmos.duplicateCount
        case .lossy: cosmos.lossyCount
        }
    }
}
