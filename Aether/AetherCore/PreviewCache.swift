import Foundation
import Harvester
import HiFiClient

/// Previews reuse the verified Harvester pipeline at 16/44.1 into ~/Library/Caches (LRU, 500 MB cap).
actor PreviewCache {
    private let directory: URL
    private let limitBytes: Int64

    init(directory: URL = URL.cachesDirectory.appending(path: "Aether/Preview"), limitBytes: Int64 = 500_000_000) {
        self.directory = directory
        self.limitBytes = limitBytes
    }

    func file(for track: TidalTrack, client: HiFiClient) async throws -> URL {
        let folder = directory.appending(path: "\(track.id)", directoryHint: .isDirectory)
        if let existing = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "flac" }) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: existing.path)
            return existing
        }
        let session = SegmentFetcher.makeAudioSession()
        let pipeline = HarvestPipeline(client: HiFiClient(baseURL: client.baseURL, session: session),
                                       fetcher: SegmentFetcher(session: session), albumLookup: { _ in nil })
        let request = HarvestRequest(track: track, destinationFolder: folder, genre: nil, policy: .lossless)
        let result = try await pipeline.execute(request) { _ in }
        purge()
        return result.fileURL
    }

    func purge() {
        let files = Self.listFlacs(in: directory)
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.date < $1.date }) where total > limitBytes {
            try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
            total -= file.size
        }
    }

    /// Synchronous: NSDirectoryEnumerator iteration is unavailable from async contexts.
    private nonisolated static func listFlacs(in directory: URL) -> [(url: URL, date: Date, size: Int64)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var files: [(url: URL, date: Date, size: Int64)] = []
        for case let url as URL in enumerator where url.pathExtension == "flac" {
            let v = try? url.resourceValues(forKeys: Set(keys))
            files.append((url, v?.contentModificationDate ?? .distantPast, Int64(v?.totalFileAllocatedSize ?? 0)))
        }
        return files
    }
}
