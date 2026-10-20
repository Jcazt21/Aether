import Observation

@MainActor
@Observable
final class AppModel {
    let preferences: Preferences
    let harvester: HarvesterStore
    let cosmos: CosmosStore
    let player: PlayerModel
    var route: Route = .harvesterSearch
    var isInspectorPresented = false

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        harvester = HarvesterStore(preferences: preferences)
        cosmos = CosmosStore(preferences: preferences)
        player = PlayerModel(preferences: preferences)
        // Owned by the model, not a view: downloads and the folder watcher keep running with the window closed.
        Task { [harvester] in await harvester.start() }
        Task { [cosmos] in await cosmos.start() }
        cosmos.onLookupChanged = { [harvester] lookup in harvester.masterLookup = lookup }
        cosmos.onRelocated = { [harvester] moves in Task { await harvester.relocate(moves) } }
    }
}
