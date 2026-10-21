import SwiftUI

struct SidebarView: View {
    @Binding var route: Route
    @Environment(HarvesterStore.self) private var harvester
    @Environment(CosmosStore.self) private var cosmos
    @Environment(Preferences.self) private var preferences
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        List(selection: Binding<Route?>(get: { route }, set: { if let new = $0 { route = new } })) {
            Section("Hermes") {
                Label("Search", systemImage: "magnifyingglass").tag(Route.harvesterSearch)
                Label("Queue", systemImage: "arrow.down.circle")
                    .badge(harvester.activeCount)
                    .tag(Route.harvesterQueue)
                Label("History", systemImage: "clock").tag(Route.harvesterHistory)
            }
            Section("Cosmos") {
                Label("Master", systemImage: "folder").tag(Route.cosmosAll)
                Label("Inbox", systemImage: "tray")
                    .badge(cosmos.inboxCount)
                    .tag(Route.cosmosInbox)
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
            Section("Review") {
                ForEach(ReviewFilter.allCases, id: \.self) { filter in
                    Label(filter.title, systemImage: filter.symbol)
                        .badge(count(for: filter))
                        .tag(Route.cosmosReview(filter))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text("Pre-alpha v1")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Tokens.Space.m)
                .padding(.vertical, Tokens.Space.s)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Image("AetherLockup")
                .resizable()
                .scaledToFit()
                .frame(height: 28)
                .padding(.horizontal, Tokens.Space.m)
                .padding(.bottom, Tokens.Space.s)
                .accessibilityLabel("Aether")
        }
    }

    private func count(for filter: ReviewFilter) -> Int {
        switch filter {
        case .untagged: cosmos.untaggedCount
        case .duplicates: cosmos.duplicateCount
        case .lossy: cosmos.lossyCount
        }
    }
}
