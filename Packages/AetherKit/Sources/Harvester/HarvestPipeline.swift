public import FlacKit
public import Foundation
public import HiFiClient
import OSLog
import TagKit

public struct HarvestPipeline: Sendable {
    private static let log = Logger(subsystem: "com.jazar.Aether", category: "harvester")
    private static let signposter = OSSignposter(logger: log)

    private let client: HiFiClient
    private let fetcher: SegmentFetcher
    private let albumLookup: @Sendable (Int) async -> TidalAlbum?
    private let now: @Sendable () -> Date

    public init(client: HiFiClient, fetcher: SegmentFetcher,
                albumLookup: @escaping @Sendable (Int) async -> TidalAlbum?,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.fetcher = fetcher
        self.albumLookup = albumLookup
        self.now = now
    }

    public static func partURL(for request: HarvestRequest) -> URL {
        request.destinationFolder.appending(path: ".\(request.id.uuidString).aether-part")
    }

    @concurrent
    public func execute(_ request: HarvestRequest, resume: AssemblerCheckpoint? = nil,
                        checkpoint: (@Sendable (AssemblerCheckpoint) -> Void)? = nil,
                        emit: @escaping @Sendable (HarvestPhase) -> Void) async throws -> HarvestResult {
        let part = Self.partURL(for: request)
        do {
            return try await run(request, part: part, resume: resume, checkpoint: checkpoint, emit: emit)
        } catch {
            if !(error is CancellationError) { try? FileManager.default.removeItem(at: part) }
            throw error
        }
    }

    private func run(_ request: HarvestRequest, part: URL, resume: AssemblerCheckpoint?,
                     checkpoint: (@Sendable (AssemblerCheckpoint) -> Void)?,
                     emit: @escaping @Sendable (HarvestPhase) -> Void) async throws -> HarvestResult {
        let track = request.track
        emit(.resolving)

        // 1. Resolve — metadata and artwork in parallel with the manifest, so the FLAC header is final before audio.
        async let album = albumLookup(track.album?.id ?? 0)
        async let artwork = fetchArtwork(track)
        var info = try await client.playbackInfo(trackID: track.id, quality: request.policy.initialQuality)
        if request.policy == .hiResCapped96, (info.sampleRate ?? 0) > 96_000 {
            info = try await client.playbackInfo(trackID: track.id, quality: .lossless)
        }
        var manifest = try info.dashManifest()
        let config = try FMP4Flac.parseInit(try await fetcher.fetch(manifest.initializationURL))
        let tags = TagBuilder.tags(track: track, album: await album, genre: request.genre,
                                   artwork: await artwork.map { TrackTags.Artwork(data: $0, mimeType: "image/jpeg") })

        // 2. Download — header first, then frames segment by segment.
        try FileManager.default.createDirectory(at: request.destinationFolder, withIntermediateDirectories: true)
        let assembler: FlacAssembler
        if let resume, FileManager.default.fileExists(atPath: part.path) {
            assembler = try FlacAssembler(resuming: part, from: resume)
        } else {
            let header = FlacHeader(blocks: config.metadataBlocks, audioOffset: 0)
            var blocks = try FlacTags.blocks(applying: tags, to: header, extraFields: TagBuilder.replayGainFields(info))
            blocks.append(.padding(8192))
            assembler = try FlacAssembler(partURL: part, headerBlocks: blocks)
        }

        let downloadInterval = Self.signposter.beginInterval("download", id: Self.signposter.makeSignpostID())
        var throttle = ProgressThrottle()
        var meter = ThroughputMeter()
        var received: Int64 = 0
        let numbers = Array(manifest.segmentNumbers)
        for (index, number) in numbers.enumerated().dropFirst(assembler.checkpoint.segmentsWritten) {
            try Task.checkCancellation()
            let bytes: [UInt8]
            do {
                bytes = try await fetcher.fetch(manifest.mediaURL(number: number))
            } catch HarvestError.http(403) {
                Self.log.info("segment \(number) expired; refreshing manifest")
                info = try await client.playbackInfo(trackID: track.id, quality: AudioQuality(rawValue: info.audioQuality) ?? .lossless)
                manifest = try info.dashManifest()
                bytes = try await fetcher.fetch(manifest.mediaURL(number: number))
            }
            try assembler.append(segment: bytes)
            checkpoint?(assembler.checkpoint)
            received += Int64(bytes.count)
            meter.add(bytes.count)
            if throttle.shouldEmit() || index == numbers.count - 1 {
                emit(.downloading(segment: index + 1, of: numbers.count, bytes: received, bytesPerSecond: meter.bytesPerSecond))
            }
        }
        try assembler.finish()
        Self.signposter.endInterval("download", downloadInterval)

        // 3. Verify — frame CRCs, sample counts (vs. MPD timeline) and PCM MD5 vs. the source MD5.
        emit(.verifying(0))
        let verifyInterval = Self.signposter.beginInterval("verify", id: Self.signposter.makeSignpostID())
        var verifyThrottle = ProgressThrottle()
        let report = try IntegrityVerifier.verify(flacAt: part, expectedSamples: manifest.totalSamples) { fraction in
            if verifyThrottle.shouldEmit() { emit(.verifying(fraction)) }
        }
        Self.signposter.endInterval("verify", verifyInterval)
        guard report.verdict == .verified else { throw HarvestError.integrity(report.failure ?? "Integridad") }

        // 4. Finalize — stamp verification (in place, inside padding) and move atomically.
        try FlacTags.write(tags, to: part, extraFields: TagBuilder.replayGainFields(info).merging(
            [IntegrityVerifier.verifiedFieldKey: IntegrityVerifier.verifiedFieldValue(report, at: now())]) { $1 })
        let base = FileNaming.baseName(artist: track.primaryArtistName, title: track.displayTitle, fallback: "tidal-\(track.id)")
        let final = try Self.moveToUniqueName(part, folder: request.destinationFolder, baseName: base)

        let si = config.streamInfo
        let size = (try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return HarvestResult(
            fileURL: final, report: report,
            format: FormatSummary(sampleRate: Int(si.sampleRate), bitDepth: Int(si.bitsPerSample),
                                  channels: Int(si.channels), duration: si.duration),
            bytes: size, finishedAt: now())
    }
}

extension HarvestPipeline {
    private func fetchArtwork(_ track: TidalTrack) async -> Data? {
        guard let cover = track.album?.cover else { return nil }
        return await fetcher.fetchOptional(client.coverURL(cover))
    }

    /// Concurrent jobs may target the same name: retry with the next free counter instead of failing.
    static func moveToUniqueName(_ source: URL, folder: URL, baseName: String) throws -> URL {
        for _ in 0..<20 {
            let candidate = FileNaming.uniqueURL(in: folder, baseName: baseName, extension: "flac")
            do {
                try FileManager.default.moveItem(at: source, to: candidate)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
