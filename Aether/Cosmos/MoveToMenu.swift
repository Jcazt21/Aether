import Cosmos
import SwiftUI

struct MoveToMenu: View {
    let items: [Cosmos.LibraryItem]
    @Environment(CosmosStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Menu("Mover a") {
            ForEach(store.folders) { folder in
                Button(folder.name) { Task { await store.move(items, toFolder: folder.name, undoManager: undoManager) } }
                    .disabled(items.allSatisfy { $0.folder == folder.name })
            }
        }
        .disabled(items.isEmpty)
    }
}
