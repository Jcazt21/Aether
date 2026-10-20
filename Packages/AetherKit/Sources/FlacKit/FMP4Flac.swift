import ByteKit
public import TagKit

public struct FlacTrackConfig: Equatable, Sendable {
    public var streamInfo: StreamInfo
    /// Metadata blocks exactly as carried in `dfLa` (STREAMINFO first).
    public var metadataBlocks: [FlacBlock]
}

public struct MediaSegment: Equatable, Sendable {
    /// Byte ranges (into the segment) holding raw FLAC frames, in order.
    public var frameRanges: [Range<Int>]
    /// Sum of sample durations in timescale units (== PCM frames when timescale == sample rate).
    public var samples: UInt64
    public var sampleCount: Int
    public var byteCount: Int
}

public enum FMP4Flac {
    public static func parseInit(_ bytes: [UInt8]) throws -> FlacTrackConfig {
        guard let dfLa = try MP4.find(["moov", "trak", "mdia", "minf", "stbl", "stsd", "fLaC", "dfLa"], in: bytes) else {
            throw MP4Error.missing("dfLa")
        }
        let blocks = Array(bytes[(dfLa.payload.lowerBound + 4)..<dfLa.payload.upperBound])
        let header = try FlacMetadataIO.parse(Array("fLaC".utf8) + blocks)
        return FlacTrackConfig(streamInfo: try header.streamInfo(), metadataBlocks: header.blocks)
    }

    public static func parseMediaSegment(_ bytes: [UInt8]) throws -> MediaSegment {
        var result = MediaSegment(frameRanges: [], samples: 0, sampleCount: 0, byteCount: 0)
        var pending: (sizes: Int?, samples: UInt64, count: Int)?
        for box in try MP4.children(of: bytes, in: 0..<bytes.count) {
            switch box.type {
            case "moof":
                pending = try parseMoof(bytes, box)
            case "mdat":
                guard let fragment = pending else { throw MP4Error.missing("moof") }
                if let expected = fragment.sizes, expected != box.payload.count {
                    throw MP4Error.segmentSizeMismatch(expected: expected, actual: box.payload.count)
                }
                result.frameRanges.append(box.payload)
                result.samples += fragment.samples
                result.sampleCount += fragment.count
                result.byteCount += box.payload.count
                pending = nil
            default:
                continue
            }
        }
        guard !result.frameRanges.isEmpty else { throw MP4Error.missing("mdat") }
        return result
    }

    private static func parseMoof(_ bytes: [UInt8], _ moof: MP4Box) throws -> (sizes: Int?, samples: UInt64, count: Int) {
        var totalSize: Int? = 0
        var totalSamples: UInt64 = 0
        var totalCount = 0
        for traf in try MP4.children(of: bytes, in: moof.payload) where traf.type == "traf" {
            var defaultDuration: UInt32?
            var defaultSize: UInt32?
            for child in try MP4.children(of: bytes, in: traf.payload) {
                var r = ByteReader(Array(bytes[child.payload]))
                switch child.type {
                case "tfhd":
                    let flags = try r.u32BE() & 0xFF_FFFF
                    try r.skip(4)
                    if flags & 0x01 != 0 { try r.skip(8) }
                    if flags & 0x02 != 0 { try r.skip(4) }
                    if flags & 0x08 != 0 { defaultDuration = try r.u32BE() }
                    if flags & 0x10 != 0 { defaultSize = try r.u32BE() }
                case "trun":
                    let flags = try r.u32BE() & 0xFF_FFFF
                    let count = Int(try r.u32BE())
                    if flags & 0x001 != 0 { try r.skip(4) }
                    if flags & 0x004 != 0 { try r.skip(4) }
                    for _ in 0..<count {
                        let duration: UInt32? = try flags & 0x100 != 0 ? r.u32BE() : defaultDuration
                        let size: UInt32? = try flags & 0x200 != 0 ? r.u32BE() : defaultSize
                        if flags & 0x400 != 0 { try r.skip(4) }
                        if flags & 0x800 != 0 { try r.skip(4) }
                        guard let duration else { throw MP4Error.unsupported("sample duration from trex") }
                        totalSamples += UInt64(duration)
                        if let size, let running = totalSize { totalSize = running + Int(size) } else { totalSize = nil }
                    }
                    totalCount += count
                default:
                    continue
                }
            }
        }
        return (totalSize, totalSamples, totalCount)
    }
}
