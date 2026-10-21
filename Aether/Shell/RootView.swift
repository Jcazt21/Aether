import AppKit
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
        .inspector(isPresented: $model.isInspectorPresented) {
            TagInspectorView()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TransportBar()
        }
        .onKeyPress(.space) {
            // Toolbar text fields sit outside this view's responder chain, so check the first responder explicitly.
            if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
            model.player.toggle()
            return .handled
        }
        .onChange(of: model.preferences.hifiBaseURL) { model.harvester.applyPreferences() }
        .onChange(of: model.preferences.maxConcurrentDownloads) { model.harvester.applyPreferences() }
        .onChange(of: model.route, initial: true) { _, route in
            switch route {
            case .cosmosAll, .cosmosFolder, .cosmosInbox, .cosmosReview: model.cosmos.scope = route
            case .harvesterSearch: model.harvester.applyDeferredLookup()
            default: break
            }
        }
    }
}

/// Each plan replaces its routes' unavailable states with the real screen.
struct DetailRouter: View {
    let route: Route

    var body: some View {
        switch route {
        case .harvesterSearch:
            HarvesterSearchView()
        case .harvesterQueue:
            HarvesterQueueView()
        case .harvesterHistory:
            HarvesterHistoryView()
        case .cosmosAll, .cosmosFolder, .cosmosInbox, .cosmosReview:
            CosmosBrowserView()
        }
    }
}
