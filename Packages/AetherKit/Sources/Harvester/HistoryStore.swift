public import FlacKit
public import Foundation

public struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var trackID: Int
    public var title: String
    public var artist: String
    public var album: String?
    public var genre: String?
    public var fileURL: URL
    public var report: IntegrityReport
    public var format: FormatSummary
    public var bytes: Int64
    public var finishedAt: Date

    public init(id: UUID, trackID: Int, title: String, artist: String, album: String?, genre: String?, fileURL: URL,
                report: IntegrityReport, format: FormatSummary, bytes: Int64, finishedAt: Date) {
        self.id = id
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.fileURL = fileURL
        self.report = report
        self.format = format
        self.bytes = bytes
        self.finishedAt = finishedAt
    }

    public init(request: HarvestRequest, result: HarvestResult) {
        self.init(id: request.id, trackID: request.track.id, title: request.track.displayTitle,
                  artist: request.track.allArtistNames, album: request.track.album?.title, genre: request.genre,
                  fileURL: result.fileURL, report: result.report, format: result.format, bytes: result.bytes,
                  finishedAt: result.finishedAt)
    }
}

public actor HistoryStore {
    private let fileURL: URL
    private let limit: Int
    private var entries: [HistoryEntry]

    public init(fileURL: URL, limit: Int = 5000) {
        self.fileURL = fileURL
        self.limit = limit
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HistoryEntry].self, from: Data(contentsOf: fileURL))) ?? []
    }

    public func all() -> [HistoryEntry] { entries }

    public func append(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
    }

    /// Keeps history (and the rekordbox XML generated from it) in sync with Cosmos moves/renames.
    public func relocate(from old: URL, to new: URL) {
        guard let index = entries.firstIndex(where: { $0.fileURL.standardizedFileURL == old.standardizedFileURL }) else { return }
        entries[index].fileURL = new
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(entries).write(to: fileURL, options: .atomic)
    }
}
