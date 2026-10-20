public import Foundation
public import TagKit

public struct AssemblerCheckpoint: Codable, Equatable, Sendable {
    public var validLength: Int
    public var samplesWritten: UInt64
    public var segmentsWritten: Int
}

/// Streams a native FLAC to disk: complete metadata header first (tags + artwork + padding), then the raw
/// frames of each DASH segment as it arrives. Memory use is one segment at a time.
/// Not thread-safe: owned by a single download task.
public final class FlacAssembler {
    public let partURL: URL
    private let handle: FileHandle
    public private(set) var checkpoint: AssemblerCheckpoint

    public init(partURL: URL, headerBlocks: [FlacBlock]) throws {
        self.partURL = partURL
        let header = try FlacMetadataIO.serialize(headerBlocks)
        guard FileManager.default.createFile(atPath: partURL.path, contents: Data(header)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: partURL)
        try handle.seekToEnd()
        checkpoint = AssemblerCheckpoint(validLength: header.count, samplesWritten: 0, segmentsWritten: 0)
    }

    public init(resuming partURL: URL, from checkpoint: AssemblerCheckpoint) throws {
        self.partURL = partURL
        handle = try FileHandle(forWritingTo: partURL)
        try handle.truncate(atOffset: UInt64(checkpoint.validLength))
        try handle.seekToEnd()
        self.checkpoint = checkpoint
    }

    @discardableResult
    public func append(segment bytes: [UInt8]) throws -> MediaSegment {
        let parsed = try FMP4Flac.parseMediaSegment(bytes)
        for range in parsed.frameRanges { try handle.write(contentsOf: bytes[range]) }
        checkpoint.validLength += parsed.byteCount
        checkpoint.samplesWritten += parsed.samples
        checkpoint.segmentsWritten += 1
        return parsed
    }

    public func finish() throws {
        try handle.synchronize()
        try handle.close()
    }
}
