public import Foundation
import ByteKit

public enum ChunkError: Error, Equatable, Sendable { case notChunked }

/// ID3v2 stored as a chunk: `id3 ` in RIFF/WAVE (little-endian sizes), `ID3 ` in FORM/AIFF (big-endian).
/// Only chunk headers are read; audio is never loaded.
public enum ChunkID3IO {
    private enum Kind { case riff, aiff }
    private struct Chunk { let id: String; let offset: Int; let size: Int; var end: Int { offset + 8 + size + (size & 1) } }

    public static func read(_ url: URL) throws -> TrackTags {
        let (_, chunks, _) = try layout(url)
        guard let chunk = chunks.first(where: { isID3($0.id) }) else { return TrackTags() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(chunk.offset + 8))
        return TrackTags(id3: try ID3Tag.parse(try handle.readExactly(chunk.size)))
    }

    public static func write(_ tags: TrackTags, to url: URL) throws {
        let (kind, chunks, fileSize) = try layout(url)
        let existing = chunks.first { isID3($0.id) }
        var tag = ID3Tag(majorVersion: 3)
        if let existing {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: UInt64(existing.offset + 8))
            tag = try ID3Tag.parse(try handle.readExactly(existing.size))
            try handle.close()
        }
        tags.apply(to: &tag)
        let tagBytes = tag.serialize(minimumSize: 0, padding: 1024)
        var chunk = ByteWriter()
        chunk.ascii(kind == .riff ? "id3 " : "ID3 ")
        if kind == .riff { chunk.u32LE(UInt32(tagBytes.count)) } else { chunk.u32BE(UInt32(tagBytes.count)) }
        chunk.append(tagBytes)
        if tagBytes.count % 2 == 1 { chunk.u8(0) }

        if let existing, existing.end < fileSize {
            try rewriteWithout(existing, appending: chunk.bytes, kind: kind, url: url, fileSize: fileSize)
        } else {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let cut = existing?.offset ?? fileSize + (fileSize & 1)
            try handle.truncate(atOffset: UInt64(cut))
            try handle.seek(toOffset: UInt64(cut))
            try handle.write(contentsOf: chunk.bytes)
            try patchContainerSize(handle, kind: kind, newFileSize: cut + chunk.bytes.count)
            try handle.synchronize()
        }
    }

    private static func isID3(_ id: String) -> Bool { id.lowercased() == "id3 " }

    private static func layout(_ url: URL) throws -> (Kind, [Chunk], Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        guard fileSize >= 12 else { throw ChunkError.notChunked }
        let head = try handle.readExactly(12)
        let magic = String(decoding: head[0..<4], as: UTF8.self)
        let form = String(decoding: head[8..<12], as: UTF8.self)
        let kind: Kind
        switch (magic, form) {
        case ("RIFF", "WAVE"): kind = .riff
        case ("FORM", "AIFF"), ("FORM", "AIFC"): kind = .aiff
        default: throw ChunkError.notChunked
        }
        var chunks: [Chunk] = []
        var offset = 12
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: UInt64(offset))
            let h = try handle.readExactly(8)
            var r = ByteReader(Array(h[4..<8]))
            let size = try Int(kind == .riff ? r.u32LE() : r.u32BE())
            let chunk = Chunk(id: String(decoding: h[0..<4], as: UTF8.self), offset: offset, size: size)
            chunks.append(chunk)
            offset = chunk.end
        }
        return (kind, chunks, fileSize)
    }

    private static func patchContainerSize(_ handle: FileHandle, kind: Kind, newFileSize: Int) throws {
        var w = ByteWriter()
        if kind == .riff { w.u32LE(UInt32(newFileSize - 8)) } else { w.u32BE(UInt32(newFileSize - 8)) }
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: w.bytes)
    }

    private static func rewriteWithout(_ skipped: Chunk, appending newChunk: [UInt8], kind: Kind, url: URL, fileSize: Int) throws {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).aether-tmp")
        guard fm.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let input = try FileHandle(forReadingFrom: url)
            let output = try FileHandle(forUpdating: temp)
            func copy(_ range: Range<Int>) throws {
                try input.seek(toOffset: UInt64(range.lowerBound))
                var remaining = range.count
                while remaining > 0, let chunk = try input.read(upToCount: min(remaining, 1 << 20)), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                    remaining -= chunk.count
                }
            }
            try copy(0..<skipped.offset)
            try copy(skipped.end..<fileSize)
            let end = Int(try output.seekToEnd())
            if end % 2 == 1 { try output.write(contentsOf: [0]) }
            try output.write(contentsOf: newChunk)
            try patchContainerSize(output, kind: kind, newFileSize: Int(try output.seekToEnd()))
            try output.synchronize()
            try output.close()
            try input.close()
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
