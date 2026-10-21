import Cosmos
import SwiftUI

typealias LibraryItem = Cosmos.LibraryItem

struct TagInspectorView: View {
    @Environment(CosmosStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @State private var draft: TagDraft?
    @State private var isSaving = false

    private var items: [LibraryItem] { store.selectedItems }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("No Selection", systemImage: "tag", description: Text("Select one or more tracks."))
            } else if let draft {
                form(draft)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        .task(id: store.selection) {
            draft = nil
            guard !items.isEmpty else { return }
            draft = TagDraft(tags: await store.loadFullTags(items))
        }
    }

    private func form(_ draft: TagDraft) -> some View {
        Form {
            Section {
                HStack { Spacer(); ArtworkWell(draft: draft); Spacer() }
                if items.contains(where: { !TagIO.isWritable(store.url(for: $0)) }) {
                    Label("Some files are read-only (M4A).", systemImage: "lock")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            section("Track", [.title, .artist, .remixer], draft)
            section("Release", [.album, .albumArtist, .label, .year, .isrc], draft)
            section("DJ", [.genre, .bpm, .key, .comment], draft)
            if items.count == 1, let item = items.first { technical(item) }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                Button("Revert") { self.draft = nil; Task { self.draft = TagDraft(tags: await store.loadFullTags(items)) } }
                    .disabled(!draft.hasChanges || isSaving)
                Button("Save") {
                    isSaving = true
                    Task {
                        await store.saveTags(draft, for: items, undoManager: undoManager)
                        self.draft = TagDraft(tags: await store.loadFullTags(items))
                        isSaving = false
                    }
                }
                .keyboardShortcut("s")
                .disabled(!draft.hasChanges || isSaving)
            }
        }
    }

    private func section(_ title: LocalizedStringKey, _ fields: [TagField], _ draft: TagDraft) -> some View {
        Section {
            ForEach(fields) { field in
                TextField(field.label, text: draft.binding(field), prompt: draft.mixed.contains(field) ? Text("Various") : nil)
                    .font(field.isNumeric || field == .isrc || field == .key ? .readout : .body)
            }
        } header: { SectionLabel(title) }
    }

    private func technical(_ item: LibraryItem) -> some View {
        Section {
            LabeledContent("Format") { Readout(item.format.label, tone: .primary) }
            LabeledContent("Channels") { Readout("\(item.format.channels)") }
            LabeledContent("Size") { Readout(item.fileSize.formatted(.byteCount(style: .file))) }
            LabeledContent("Integrity") {
                Readout(item.verifiedStamp.map { "VERIFIED · \($0.dropFirst(4).prefix(8))…" } ?? "Unverified",
                        tone: item.isVerified ? .signal : .tertiary)
            }
            LabeledContent("Path") { Readout(item.relativePath) }
        } header: { SectionLabel("Technical") }
    }
}
