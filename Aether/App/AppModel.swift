import Observation

@MainActor
@Observable
final class AppModel {
    let preferences: Preferences
    let harvester: HarvesterStore
    var route: Route = .harvesterSearch
    var isInspectorPresented = false

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        harvester = HarvesterStore(preferences: preferences)
        // Owned by the model, not a view: downloads keep reporting with the window closed.
        Task { [harvester] in await harvester.start() }
    }
}
