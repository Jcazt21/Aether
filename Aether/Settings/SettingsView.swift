import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(Preferences.self) private var preferences
    @State private var isPickingMaster = false

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                LabeledContent("Carpeta Master") {
                    HStack {
                        Readout(preferences.masterFolder.path(percentEncoded: false), tone: .primary)
                        Button("Elegir…") { isPickingMaster = true }
                    }
                }
                TextField("Carpeta de entrada", text: $preferences.inboxFolderName)
            } header: {
                SectionLabel("Biblioteca")
            }
            Section {
                TextField("URL de hifi-api", value: $preferences.hifiBaseURL, format: .url)
                    .font(.readout)
            } header: {
                SectionLabel("Fuente")
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isPickingMaster, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { preferences.masterFolder = url }
        }
    }
}
