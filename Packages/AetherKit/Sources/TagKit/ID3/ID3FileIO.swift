public import Foundation
import ByteKit

/// ID3v2 at the start of a file (MP3). ID3v1 at the end is left untouched.
public enum ID3FileIO {
    public static func readTag(_ url: URL) throws -> (tag: ID3Tag?, totalSize: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = (try handle.read(upToCount: 10)).map { [UInt8]($0) } ?? []
        guard let total = ID3Tag.declaredSize(header: head) else { return (nil, 0) }
        let body = try handle.read(upToCount: total - 10).map { [UInt8]($0) } ?? []
        return (try ID3Tag.parse(head + body), total)
    }

    public static func read(_ url: URL) throws -> TrackTags {
        try readTag(url).tag.map(TrackTags.init(id3:)) ?? TrackTags()
    }

    public static func write(_ tags: TrackTags, to url: URL) throws {
        let (existing, total) = try readTag(url)
        var tag = existing ?? ID3Tag(majorVersion: 3)
        tags.apply(to: &tag)
        try HeaderRegionRewriter.replace(fileAt: url, oldLength: total, with: tag.serialize(minimumSize: total))
    }
}
