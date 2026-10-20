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
                ContentUnavailableView("Sin selección", systemImage: "tag", description: Text("Selecciona una o varias pistas."))
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
                    Label("Algunos archivos son de solo lectura (M4A).", systemImage: "lock")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            section("Pista", [.title, .artist, .remixer], draft)
            section("Lanzamiento", [.album, .albumArtist, .label, .year, .isrc], draft)
            section("DJ", [.genre, .bpm, .key, .comment], draft)
            if items.count == 1, let item = items.first { technical(item) }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                Button("Revertir") { self.draft = nil; Task { self.draft = TagDraft(tags: await store.loadFullTags(items)) } }
                    .disabled(!draft.hasChanges || isSaving)
                Button("Guardar") {
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
                TextField(field.label, text: draft.binding(field), prompt: draft.mixed.contains(field) ? Text("Varios") : nil)
                    .font(field.isNumeric || field == .isrc || field == .key ? .readout : .body)
            }
        } header: { SectionLabel(title) }
    }

    private func technical(_ item: LibraryItem) -> some View {
        Section {
            LabeledContent("Formato") { Readout(item.format.label, tone: .primary) }
            LabeledContent("Canales") { Readout("\(item.format.channels)") }
            LabeledContent("Tamaño") { Readout(item.fileSize.formatted(.byteCount(style: .file))) }
            LabeledContent("Integridad") {
                Readout(item.verifiedStamp.map { "VERIFICADO · \($0.dropFirst(4).prefix(8))…" } ?? "Sin verificar",
                        tone: item.isVerified ? .signal : .tertiary)
            }
            LabeledContent("Ruta") { Readout(item.relativePath) }
        } header: { SectionLabel("Técnico") }
    }
}
