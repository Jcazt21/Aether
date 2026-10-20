import Darwin
public import Foundation
public import TagKit

public struct FrameScanReport: Equatable, Sendable, Codable {
    public var frames = 0
    public var samples: UInt64 = 0
    public var minFrameSize = Int.max
    public var maxFrameSize = 0
    /// Offset of the first frame whose header or CRC-16 is invalid; nil when every frame verified.
    public var firstBadOffset: Int?
    /// Frame start offsets, only when requested (tests, DASH fixture building).
    public var frameOffsets: [Int]?

    public var isClean: Bool { firstBadOffset == nil && frames > 0 }
}

/// Walks every FLAC frame without decoding: a frame ends where the next valid header begins AND the
/// CRC-16 of the bytes in between matches. Corruption fails fast (bounded search window per frame).
public enum FlacFrameScanner {
    public static func scan(fileAt url: URL, collectOffsets: Bool = false,
                            progress: ((Double) -> Void)? = nil) throws -> FrameScanReport {
        let header = try FlacMetadataIO.read(url)
        let streamInfo = try header.streamInfo()
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return data.withUnsafeBytes {
            scan($0, audioOffset: header.audioOffset, streamInfo: streamInfo, collectOffsets: collectOffsets, progress: progress)
        }
    }

    public static func scan(_ buf: UnsafeRawBufferPointer, audioOffset: Int, streamInfo: StreamInfo,
                            collectOffsets: Bool, progress: ((Double) -> Void)?) -> FrameScanReport {
        var report = FrameScanReport()
        if collectOffsets { report.frameOffsets = [] }
        let n = buf.count
        let maxBlock = Int(streamInfo.maxBlockSize)
        // Upper bound for one frame: verbatim subframes plus generous header/padding slack.
        let maxFrameBytes = streamInfo.maxFrameSize > 0
            ? Int(streamInfo.maxFrameSize) + 16
            : max(maxBlock, 4096) * Int(streamInfo.channels) * ((Int(streamInfo.bitsPerSample) + 7) / 8) + 1024
        guard let base = buf.baseAddress,
              var current = FrameHeaderParser.parse(buf, at: audioOffset, maxBlockSize: maxBlock)
        else {
            report.firstBadOffset = audioOffset
            report.minFrameSize = 0
            return report
        }

        var start = audioOffset
        var lastReport = 0
        func record(_ end: Int, _ header: FrameHeader) {
            let size = end - start
            report.frames += 1
            report.samples += UInt64(header.blockSize)
            report.minFrameSize = min(report.minFrameSize, size)
            report.maxFrameSize = max(report.maxFrameSize, size)
            report.frameOffsets?.append(start)
        }
        func storedCRC(at end: Int) -> UInt16 { UInt16(buf[end - 2]) << 8 | UInt16(buf[end - 1]) }
        func crcMatches(until end: Int) -> Bool {
            end - start >= current.headerLength + 2
                && CRC.crc16(UnsafeRawBufferPointer(rebasing: buf[start..<(end - 2)])) == storedCRC(at: end)
        }

        while true {
            let limit = min(n - 1, start + maxFrameBytes)
            var i = start + current.headerLength
            var next: (offset: Int, header: FrameHeader)?
            while i < limit, let hit = memchr(base + i, 0xFF, limit - i) {
                let j = base.distance(to: UnsafeRawPointer(hit))
                if buf[j + 1] & 0xFE == 0xF8,
                   let h = FrameHeaderParser.parse(buf, at: j, maxBlockSize: maxBlock),
                   crcMatches(until: j) {
                    next = (j, h)
                    break
                }
                i = j + 1
            }

            if let next {
                record(next.offset, current)
                start = next.offset
                current = next.header
                if let progress, start - lastReport >= 1 << 20 {
                    progress(Double(start) / Double(n))
                    lastReport = start
                }
                continue
            }
            if n - start <= maxFrameBytes, crcMatches(until: n) {
                record(n, current)
            } else {
                report.firstBadOffset = start
            }
            break
        }
        if report.frames == 0 { report.minFrameSize = 0 }
        progress?(1)
        return report
    }
}
