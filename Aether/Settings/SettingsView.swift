import AppKit
import Harvester
import HiFiClient
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Hermes", systemImage: "arrow.down.circle") { HarvesterSettings() }
            Tab("Lyra", systemImage: "waveform") { CoreSettings() }
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

private struct HarvesterSettings: View {
    @Environment(Preferences.self) private var preferences
    @State private var connection: Bool?

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Picker("Calidad", selection: $preferences.qualityPolicyRaw) {
                    ForEach(QualityPolicy.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Stepper("Descargas simultáneas: \(preferences.maxConcurrentDownloads)",
                        value: $preferences.maxConcurrentDownloads, in: 1...4)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Plantilla de nombre", text: $preferences.filenameTemplate)
                        .font(.readout)
                    Text("Personaliza el nombre de los archivos descargados. Disponibles: {discNumber}, {trackNumber}, {artist}, {title}, {album}")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: { SectionLabel("Descarga") }
            Section {
                Toggle("Mantener rekordbox.xml", isOn: $preferences.rekordboxXMLEnabled)
                LabeledContent("Archivo") {
                    HStack {
                        Readout(preferences.rekordboxXMLURL.path(percentEncoded: false))
                        Button("Mostrar") { NSWorkspace.shared.activateFileViewerSelecting([preferences.rekordboxXMLURL]) }
                    }
                }
                Text("En rekordbox: Preferencias › Avanzado › Base de datos › rekordbox xml → elige este archivo.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { SectionLabel("rekordbox") }
            Section {
                LabeledContent("hifi-api") {
                    HStack {
                        Readout(preferences.hifiBaseURL.absoluteString)
                        Button("Probar") {
                            Task { connection = await HiFiClient(baseURL: preferences.hifiBaseURL).ping() }
                        }
                        if let connection {
                            Image(systemName: connection ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(connection ? Tokens.signal : Tokens.fault)
                                .accessibilityLabel(connection ? "Conectado" : "Sin conexión")
                        }
                    }
                }
            } header: { SectionLabel("Conexión") }
        }
        .formStyle(.grouped)
    }
}

private struct CoreSettings: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Toggle("Bit-perfect: ajustar el sample rate del DAC a cada pista", isOn: $preferences.bitPerfect)
                Text("Aether devuelve el sample rate original al salir. El volumen se controla en el sistema o en el DAC.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { SectionLabel("Salida") }
        }
        .formStyle(.grouped)
    }
}
