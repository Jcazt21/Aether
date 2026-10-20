import AppKit
import Cosmos
import Foundation
import Harvester
import HiFiClient
import Observation
import UserNotifications

enum SearchScope: String, CaseIterable {
    case tracks, albums
    var title: String { self == .tracks ? "Pistas" : "Álbumes" }
}

@MainActor
@Observable
final class HarvesterStore {
    private(set) var jobs: [JobModel] = []
    private(set) var history: [HistoryEntry] = []
    var searchQuery = ""
    var searchScope: SearchScope = .tracks
    private(set) var trackResults: [TidalTrack] = []
    private(set) var albumResults: [TidalAlbum] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    var selectedTrackIDs: Set<Int> = []
    var destination: URL
    private(set) var destinationFolders: [URL] = []
    var masterLookup: MasterLookup = .empty
    var pendingDuplicates: [TidalTrack]?

    var activeCount: Int { jobs.count { !$0.phase.isTerminal } }
    var failedCount: Int { jobs.count { if case .failed = $0.phase { true } else { false } } }

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var client: HiFiClient
    @ObservationIgnored private let engine: HarvestEngine
    @ObservationIgnored private let historyStore = HistoryStore(fileURL: AppPaths.history)
    @ObservationIgnored private var jobsByID: [UUID: JobModel] = [:]
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var batchVerified = 0
    @ObservationIgnored private var batchFailed = 0

    init(preferences: Preferences) {
        self.preferences = preferences
        destination = preferences.inboxFolder
        client = HiFiClient(baseURL: preferences.hifiBaseURL)
        engine = HarvestEngine(pipeline: Self.pipeline(client: client),
                               checkpoints: CheckpointStore(fileURL: AppPaths.checkpoints),
                               maxConcurrent: preferences.maxConcurrentDownloads)
    }

    private static func pipeline(client: HiFiClient) -> HarvestPipeline {
        let session = SegmentFetcher.makeAudioSession()
        let albums = AlbumCache(client: client)
        return HarvestPipeline(client: HiFiClient(baseURL: client.baseURL, session: session),
                               fetcher: SegmentFetcher(session: session),
                               albumLookup: { await albums.album($0) })
    }

    // MARK: Lifecycle

    func start() async {
        history = await historyStore.all()
        refreshDestinationFolders()
        if let data = try? Data(contentsOf: AppPaths.queue),
           let pending = try? JSONDecoder().decode([HarvestRequest].self, from: data), !pending.isEmpty {
            register(pending)
            await engine.enqueue(pending)
        }
        for await event in engine.events { await handle(event) }
    }

    func applyPreferences() {
        client = HiFiClient(baseURL: preferences.hifiBaseURL)
        let pipeline = Self.pipeline(client: client)
        let max = preferences.maxConcurrentDownloads
        Task { await engine.setPipeline(pipeline); await engine.setMaxConcurrent(max) }
    }

    // MARK: Search

    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { trackResults = []; albumResults = []; searchError = nil; return }
        isSearching = true
        defer { isSearching = false }
        do {
            switch searchScope {
            case .tracks: trackResults = try await client.searchTracks(query).items
            case .albums: albumResults = try await client.searchAlbums(query).items
            }
            searchError = nil
        } catch is CancellationError {
        } catch {
            searchError = HarvestEngine.message(for: error)
        }
    }

    func loadAlbum(_ album: TidalAlbum) async -> [TidalTrack] {
        (try? await client.album(id: album.id).tracks) ?? []
    }

    // MARK: Queue

    func masterMatch(for track: TidalTrack) -> MasterLookup.Match? {
        masterLookup.match(isrc: track.isrc, artist: track.allArtistNames, title: track.displayTitle)
    }

    /// Fresh tracks start immediately; exact matches wait for an explicit decision (no silent re-downloads).
    func requestEnqueue(_ tracks: [TidalTrack]) {
        var fresh: [TidalTrack] = []
        var duplicates: [TidalTrack] = []
        for track in tracks {
            if case .exact = masterMatch(for: track) { duplicates.append(track) } else { fresh.append(track) }
        }
        if !fresh.isEmpty { enqueue(fresh) }
        pendingDuplicates = duplicates.isEmpty ? nil : duplicates
    }

    func resolvePendingDuplicates(includeDuplicates: Bool) {
        if includeDuplicates, let pending = pendingDuplicates { enqueue(pending) }
        pendingDuplicates = nil
    }

    func relocate(_ moves: [FileMove]) async {
        for move in moves { await historyStore.relocate(from: move.from, to: move.to) }
        history = await historyStore.all()
        if preferences.rekordboxXMLEnabled {
            let entries = history
            let url = preferences.rekordboxXMLURL
            await Task.detached(priority: .utility) { try? RekordboxXML.write(entries: entries, to: url) }.value
        }
    }

    func enqueue(_ tracks: [TidalTrack]) {
        let genre = destination.standardizedFileURL == preferences.inboxFolder.standardizedFileURL ? nil : destination.lastPathComponent
        let policy = QualityPolicy(rawValue: preferences.qualityPolicyRaw) ?? .hiResCapped96
        let requests = tracks.map { HarvestRequest(track: $0, destinationFolder: destination, genre: genre, policy: policy) }
        register(requests)
        Task { await engine.enqueue(requests) }
        requestNotificationPermissionOnce()
    }

    func enqueueSelection() {
        requestEnqueue(trackResults.filter { selectedTrackIDs.contains($0.id) })
    }

    func cancel(_ id: UUID) { Task { await engine.cancel(id) } }

    func retryFailed() {
        let failed = jobs.filter { if case .failed = $0.phase { true } else { false } }
        jobs.removeAll { job in failed.contains { $0.id == job.id } }
        failed.forEach { jobsByID[$0.id] = nil }
        enqueue(failed.map(\.request.track))
    }

    func clearFinished() {
        jobs.removeAll { $0.phase.isTerminal }
        jobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
    }

    func refreshDestinationFolders() {
        let master = preferences.masterFolder
        let children = (try? FileManager.default.contentsOfDirectory(at: master, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        destinationFolders = children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Events

    private func register(_ requests: [HarvestRequest]) {
        for request in requests where jobsByID[request.id] == nil {
            let job = JobModel(request: request)
            jobsByID[request.id] = job
            jobs.append(job)
        }
    }

    private func handle(_ event: HarvestEvent) async {
        guard let job = jobsByID[event.id] else { return }
        job.phase = event.phase
        if case .verified(let result) = event.phase {
            batchVerified += 1
            let entry = HistoryEntry(request: job.request, result: result)
            await historyStore.append(entry)
            history.insert(entry, at: 0)
            if preferences.rekordboxXMLEnabled {
                let entries = history
                let url = preferences.rekordboxXMLURL
                Task.detached(priority: .utility) { try? RekordboxXML.write(entries: entries, to: url) }
            }
        }
        if case .failed = event.phase { batchFailed += 1 }
        if event.phase.isTerminal || event.phase == .queued { await persistQueueAndActivity() }
    }

    private func persistQueueAndActivity() async {
        let pending = await engine.pendingRequests
        try? JSONEncoder().encode(pending).write(to: AppPaths.queue, options: .atomic)

        let active = activeCount
        NSApp.dockTile.badgeLabel = active > 0 ? "\(active)" : nil
        if active > 0, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Harvester downloads")
        } else if active == 0, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
            notifyBatchFinished()
        }
    }

    // MARK: Notifications (only when the app is in the background — HIG 7.1/7.3)

    @ObservationIgnored private var askedForNotifications = false

    private func requestNotificationPermissionOnce() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    private func notifyBatchFinished() {
        defer { batchVerified = 0; batchFailed = 0 }
        guard !NSApp.isActive, batchVerified + batchFailed > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Harvester terminó"
        content.body = batchFailed == 0
            ? "\(batchVerified) pistas verificadas"
            : "\(batchVerified) verificadas · \(batchFailed) fallidas"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Album metadata is shared by every track of an album: fetch once.
private actor AlbumCache {
    private let client: HiFiClient
    private var cache: [Int: TidalAlbum] = [:]

    init(client: HiFiClient) { self.client = client }

    func album(_ id: Int) async -> TidalAlbum? {
        if let hit = cache[id] { return hit }
        guard id != 0, let album = try? await client.album(id: id).album else { return nil }
        cache[id] = album
        return album
    }
}
