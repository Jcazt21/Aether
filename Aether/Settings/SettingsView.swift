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
                LabeledContent("Master Folder") {
                    HStack {
                        Readout(preferences.masterFolder.path(percentEncoded: false), tone: .primary)
                        Button("Choose…") { isPickingMaster = true }
                    }
                }
                TextField("Inbox Folder", text: $preferences.inboxFolderName)
            } header: {
                SectionLabel("Library")
            }
            Section {
                TextField("hifi-api URL", value: $preferences.hifiBaseURL, format: .url)
                    .font(.readout)
            } header: {
                SectionLabel("Source")
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
                Picker("Quality", selection: $preferences.qualityPolicyRaw) {
                    ForEach(QualityPolicy.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Stepper("Concurrent downloads: \(preferences.maxConcurrentDownloads)",
                        value: $preferences.maxConcurrentDownloads, in: 1...4)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Filename Template", text: $preferences.filenameTemplate)
                        .font(.readout)
                    Text("Customize the name of downloaded files. Available: {discNumber}, {trackNumber}, {artist}, {title}, {album}")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: { SectionLabel("Download") }
            Section {
                Toggle("Keep rekordbox.xml up to date", isOn: $preferences.rekordboxXMLEnabled)
                LabeledContent("File") {
                    HStack {
                        Readout(preferences.rekordboxXMLURL.path(percentEncoded: false))
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([preferences.rekordboxXMLURL]) }
                    }
                }
                Text("In rekordbox: Preferences › Advanced › Database › rekordbox xml → choose this file.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { SectionLabel("rekordbox") }
            Section {
                LabeledContent("hifi-api") {
                    HStack {
                        Readout(preferences.hifiBaseURL.absoluteString)
                        Button("Test") {
                            Task { connection = await HiFiClient(baseURL: preferences.hifiBaseURL).ping() }
                        }
                        if let connection {
                            Image(systemName: connection ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(connection ? Tokens.signal : Tokens.fault)
                                .accessibilityLabel(connection ? "Connected" : "Offline")
                        }
                    }
                }
            } header: { SectionLabel("Connection") }
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
                Toggle("Bit-perfect: match the DAC sample rate to each track", isOn: $preferences.bitPerfect)
                Text("Aether restores the original sample rate on quit. Volume is controlled by the system or the DAC.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { SectionLabel("Output") }
        }
        .formStyle(.grouped)
    }
}
