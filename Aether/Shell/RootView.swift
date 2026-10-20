import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(route: $model.route)
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300)
        } detail: {
            DetailRouter(route: model.route)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.canvas)
        }
    }
}

/// Each plan replaces its routes' unavailable states with the real screen.
struct DetailRouter: View {
    let route: Route

    var body: some View {
        switch route {
        case .harvesterSearch:
            ContentUnavailableView("Buscar en Tidal", systemImage: "magnifyingglass",
                                   description: Text("Escribe un artista, una pista o un álbum."))
        case .harvesterQueue:
            ContentUnavailableView("Cola vacía", systemImage: "arrow.down.circle",
                                   description: Text("Las descargas aparecerán aquí."))
        case .harvesterHistory:
            ContentUnavailableView("Sin historial", systemImage: "clock",
                                   description: Text("Las descargas verificadas aparecerán aquí."))
        case .cosmosAll, .cosmosFolder, .cosmosInbox, .cosmosReview:
            ContentUnavailableView("Master", systemImage: "folder",
                                   description: Text("Cosmos indexará tu carpeta Master."))
        }
    }
}
