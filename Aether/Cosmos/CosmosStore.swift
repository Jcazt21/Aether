import Cosmos
import Foundation
import Observation
import TagKit

struct FolderSummary: Identifiable, Equatable {
    let name: String
    let count: Int
    var id: String { name }
}

@MainActor
@Observable
final class CosmosStore {
    private(set) var items: [LibraryItem] = [] { didSet { recompute() } }
    private(set) var folders: [FolderSummary] = []
    private(set) var visible: [LibraryItem] = []
    private(set) var duplicateGroups: [DuplicateGroup] = []
    private(set) var lookup: MasterLookup = .empty
    private(set) var isScanning = false
    var scope: Route = .cosmosAll { didSet { if scope != oldValue { refreshVisible() } } }
    var searchText = "" { didSet { refreshVisible() } }
    var sortOrder = [KeyPathComparator(\LibraryItem.displayArtist)] { didSet { refreshVisible() } }
    var selection: Set<String> = []
    var quickLookURL: URL?
    var renamePlan: [FileMove]?
    var verifying: Set<String> = []

    @ObservationIgnored var onLookupChanged: ((MasterLookup) -> Void)?
    @ObservationIgnored var onRelocated: (([FileMove]) -> Void)?
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored let journal = MoveJournal(fileURL: AppPaths.moveJournal)
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var duplicateIDs: Set<String> = []
    @ObservationIgnored private var scanQueued = false

    init(preferences: Preferences) { self.preferences = preferences }

    var root: URL { preferences.masterFolder }
    var inboxCount: Int { items.count { $0.folder == preferences.inboxFolderName } }
    var untaggedCount: Int { items.count { $0.tags.isEffectivelyEmpty } }
    var duplicateCount: Int { duplicateIDs.count }
    var lossyCount: Int { items.count { !$0.format.isLossless } }
    var selectedItems: [LibraryItem] { visible.filter { selection.contains($0.id) } }

    func url(for item: LibraryItem) -> URL { item.url(in: root) }

    // MARK: Tags

    func loadFullTags(_ items: [LibraryItem]) async -> [TrackTags] {
        let urls = items.map(url(for:))
        return await Task.detached(priority: .userInitiated) { urls.map { (try? TagIO.read($0)) ?? TrackTags() } }.value
    }

    func saveTags(_ draft: TagDraft, for items: [LibraryItem], undoManager: UndoManager?) async {
        let urls = items.map(url(for:)).filter(TagIO.isWritable)
        let before = await Task.detached(priority: .userInitiated) { urls.map { (try? TagIO.read($0)) ?? TrackTags() } }.value
        let after = before.map(draft.applied(to:))
        await write(after, to: urls)
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in
                await store.write(before, to: urls)
                undoManager?.registerUndo(withTarget: store) { s in Task { @MainActor in await s.write(after, to: urls) } }
            }
        }
        undoManager?.setActionName(items.count == 1 ? "Editar tags" : "Editar tags de \(items.count) pistas")
    }

    private func write(_ tags: [TrackTags], to urls: [URL]) async {
        await Task.detached(priority: .userInitiated) {
            for (t, url) in zip(tags, urls) { try? TagIO.write(t, to: url) }
        }.value
        await rescan()
    }

    // MARK: Lifecycle

    func start() async {
        let cached = IndexStore.load(from: AppPaths.index, root: root)
        if !cached.isEmpty { items = cached.values.sorted { $0.relativePath < $1.relativePath } }
        await rescan()
        watcher = FolderWatcher(url: root, latency: 1.0)
        guard let changes = watcher?.changes else { return }
        for await _ in changes { await rescan() }
    }

    func rescan() async {
        guard !isScanning else { scanQueued = true; return }
        isScanning = true
        repeat {
            scanQueued = false
            let previous = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            let root = root
            let result = await LibraryScanner.scan(root: root, previous: previous)
            items = result.items
            folders = result.folders.map { name in FolderSummary(name: name, count: result.items.count { $0.folder == name }) }
            let snapshot = result.items
            Task.detached(priority: .utility) { try? IndexStore.save(snapshot, root: root, to: AppPaths.index) }
        } while scanQueued
        isScanning = false
    }

    // MARK: Derived state

    private func recompute() {
        duplicateGroups = DuplicateDetector.groups(in: items)
        duplicateIDs = Set(duplicateGroups.flatMap(\.itemIDs))
        lookup = MasterLookup(items: items)
        onLookupChanged?(lookup)
        refreshVisible()
    }

    private func refreshVisible() {
        visible = Self.filter(items, scope: scope, inbox: preferences.inboxFolderName, search: searchText, duplicates: duplicateIDs)
            .sorted(using: sortOrder)
        selection.formIntersection(visible.map(\.id))
    }

    static func filter(_ items: [LibraryItem], scope: Route, inbox: String, search: String, duplicates: Set<String>) -> [LibraryItem] {
        let scoped: [LibraryItem] = switch scope {
        case .cosmosFolder(let name): items.filter { $0.folder == name }
        case .cosmosInbox: items.filter { $0.folder == inbox }
        case .cosmosReview(.untagged): items.filter { $0.tags.isEffectivelyEmpty }
        case .cosmosReview(.duplicates): items.filter { duplicates.contains($0.id) }
        case .cosmosReview(.lossy): items.filter { !$0.format.isLossless }
        default: items
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return scoped }
        return scoped.filter {
            $0.displayArtist.localizedStandardContains(query) || $0.displayTitle.localizedStandardContains(query)
                || ($0.tags.label ?? "").localizedStandardContains(query) || $0.fileName.localizedStandardContains(query)
        }
    }
}
