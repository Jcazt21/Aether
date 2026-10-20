public import Foundation
import ByteKit

public struct FlacHeader: Equatable, Sendable {
    public var blocks: [FlacBlock]
    /// Byte offset of the first audio frame (includes any non-standard leading ID3 tag).
    public var audioOffset: Int

    public init(blocks: [FlacBlock], audioOffset: Int) {
        self.blocks = blocks
        self.audioOffset = audioOffset
    }

    public func streamInfo() throws -> StreamInfo {
        guard let first = blocks.first, first.type == FlacBlockType.streamInfo else { throw FlacError.missingStreamInfo }
        return try StreamInfo(payload: first.payload)
    }

    public func blocks(ofType type: UInt8) -> [FlacBlock] { blocks.filter { $0.type == type } }
}

public enum FlacMetadataIO {
    private static let magic: [UInt8] = Array("fLaC".utf8)
    private static let maxPayload = (1 << 24) - 1

    public static func parse(_ bytes: [UInt8]) throws -> FlacHeader {
        var r = ByteReader(bytes)
        let start = try leadingID3Length(Array(bytes.prefix(10)))
        try r.seek(to: start)
        guard bytes.count >= start + 4, try r.bytes(4) == magic else { throw FlacError.notFlac }
        var blocks: [FlacBlock] = []
        var isLast = false
        while !isLast {
            let flags = try r.u8()
            isLast = flags & 0x80 != 0
            let length = Int(try r.u24BE())
            blocks.append(FlacBlock(type: flags & 0x7F, payload: try r.bytes(length)))
        }
        guard blocks.first?.type == FlacBlockType.streamInfo else { throw FlacError.missingStreamInfo }
        return FlacHeader(blocks: blocks, audioOffset: r.offset)
    }

    public static func read(_ url: URL) throws -> FlacHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = (try handle.read(upToCount: 10)).map { [UInt8]($0) } ?? []
        let start = try leadingID3Length(head)
        try handle.seek(toOffset: UInt64(start))
        guard (try? handle.readExactly(4)) == magic else { throw FlacError.notFlac }
        var blocks: [FlacBlock] = []
        var offset = start + 4
        var isLast = false
        while !isLast {
            let h = try handle.readExactly(4)
            isLast = h[0] & 0x80 != 0
            let length = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            blocks.append(FlacBlock(type: h[0] & 0x7F, payload: try handle.readExactly(length)))
            offset += 4 + length
        }
        guard blocks.first?.type == FlacBlockType.streamInfo else { throw FlacError.missingStreamInfo }
        return FlacHeader(blocks: blocks, audioOffset: offset)
    }

    public static func serialize(_ blocks: [FlacBlock]) throws -> [UInt8] {
        var w = ByteWriter(reservingCapacity: 4 + blocks.reduce(0) { $0 + 4 + $1.payload.count })
        w.append(magic)
        for (index, block) in blocks.enumerated() {
            guard block.payload.count <= maxPayload else { throw FlacError.blockTooLarge }
            let last: UInt8 = index == blocks.count - 1 ? 0x80 : 0
            w.u8(last | (block.type & 0x7F))
            w.u24BE(UInt32(block.payload.count))
            w.append(block.payload)
        }
        return w.bytes
    }

    /// Drops existing PADDING and appends one sized to reuse `regionLength` exactly when possible,
    /// otherwise appends `padding` bytes of fresh padding (the file will be rewritten).
    public static func layout(_ blocks: [FlacBlock], regionLength: Int?, padding: Int) -> [FlacBlock] {
        var out = blocks.filter { $0.type != FlacBlockType.padding }
        let used = 4 + out.reduce(0) { $0 + 4 + $1.payload.count }
        if let region = regionLength {
            if used == region { return out }
            if used + 4 <= region {
                out.append(.padding(region - used - 4))
                return out
            }
        }
        out.append(.padding(padding))
        return out
    }

    public static func write(_ blocks: [FlacBlock], to url: URL, padding: Int = 8192) throws {
        guard blocks.first?.type == FlacBlockType.streamInfo else { throw FlacError.missingStreamInfo }
        let current = try read(url)
        let laidOut = layout(blocks, regionLength: current.audioOffset, padding: padding)
        try HeaderRegionRewriter.replace(fileAt: url, oldLength: current.audioOffset, with: try serialize(laidOut))
    }

    /// Some taggers prepend ID3v2 to FLAC (non-standard). Returns its total length, or 0.
    private static func leadingID3Length(_ head: [UInt8]) throws -> Int {
        guard head.count >= 10, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 else { return 0 }
        var r = ByteReader(Array(head[6..<10]))
        return 10 + Int(try r.syncsafe32())
    }
}
