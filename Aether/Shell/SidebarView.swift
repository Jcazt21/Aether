import SwiftUI

struct SidebarView: View {
    @Binding var route: Route

    var body: some View {
        List(selection: Binding<Route?>(get: { route }, set: { if let new = $0 { route = new } })) {
            Section("Harvester") {
                Label("Buscar", systemImage: "magnifyingglass").tag(Route.harvesterSearch)
                Label("Cola", systemImage: "arrow.down.circle").tag(Route.harvesterQueue)
                Label("Historial", systemImage: "clock").tag(Route.harvesterHistory)
            }
            Section("Cosmos") {
                Label("Master", systemImage: "folder").tag(Route.cosmosAll)
            }
        }
        .listStyle(.sidebar)
    }
}
