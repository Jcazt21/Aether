import SwiftUI

/// Toolbar menu: where Harvester writes. Folder name becomes GENRE (except the inbox).
struct DestinationMenu: View {
    @Environment(HarvesterStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Menu {
            Picker("Destino", selection: $store.destination) {
                ForEach(store.destinationFolders, id: \.self) { folder in
                    Text(folder.lastPathComponent).tag(folder)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(store.destination.lastPathComponent, systemImage: "folder")
        }
        .help("Carpeta de destino en Master")
        .onAppear { store.refreshDestinationFolders() }
    }
}
