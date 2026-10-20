import Observation

/// Owns app-wide state. Feature stores (Harvester, Cosmos, Aether Core) are added by plans 04–06.
@MainActor
@Observable
final class AppModel {
    let preferences: Preferences
    var route: Route = .harvesterSearch
    var isInspectorPresented = false

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
    }
}
