import FlacKit
public import Foundation
public import TagKit

public struct LibraryItem: Codable, Sendable, Identifiable, Equatable {
    public var relativePath: String
    public var fileSize: Int64
    public var modified: Date
    public var format: AudioFormatInfo
    public var tags: TrackTags
    public var hasArtwork: Bool
    public var verifiedStamp: String?

    public init(relativePath: String, fileSize: Int64, modified: Date, format: AudioFormatInfo, tags: TrackTags,
                hasArtwork: Bool, verifiedStamp: String?) {
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.modified = modified
        self.format = format
        self.tags = tags
        self.hasArtwork = hasArtwork
        self.verifiedStamp = verifiedStamp
    }

    public var id: String { relativePath }
    public var fileName: String { (relativePath as NSString).lastPathComponent }
    /// First path component (genre folder), "" for files at the Master root.
    public var folder: String {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count > 1 ? String(parts[0]) : ""
    }

    private var nameParts: (artist: String?, title: String) {
        let stem = (fileName as NSString).deletingPathExtension
        guard let range = stem.range(of: " - ") else { return (nil, stem) }
        return (String(stem[..<range.lowerBound]), String(stem[range.upperBound...]))
    }

    public var displayArtist: String { tags.artist ?? nameParts.artist ?? "" }
    public var displayTitle: String { tags.title ?? nameParts.title }
    public var bpmValue: Double { tags.bpm ?? 0 }
    public var keyValue: String { tags.key ?? "" }
    public var genreValue: String { tags.genre ?? "" }
    public var durationValue: Double { format.duration }
    public var isVerified: Bool { verifiedStamp != nil }

    public func url(in root: URL) -> URL { root.appending(path: relativePath) }
}

public enum ItemReader {
    public static func read(url: URL, relativePath: String, fileSize: Int64, modified: Date) throws -> LibraryItem {
        if url.pathExtension.lowercased() == "flac",
           let (header, hasPicture) = try? FlacMetadataIO.readSkippingPictures(url),
           let si = try? header.streamInfo() {
            let format = AudioFormatInfo(codec: .flac, sampleRate: Double(si.sampleRate), bitDepth: Int(si.bitsPerSample),
                                         channels: Int(si.channels), duration: si.duration, bitRate: nil)
            let vorbis = (try? header.blocks(ofType: FlacBlockType.vorbisComment).first.map { try VorbisComment(payload: $0.payload) }) ?? VorbisComment()
            let tags = TrackTags(vorbis: vorbis, frontCover: nil)
            return LibraryItem(relativePath: relativePath, fileSize: fileSize, modified: modified, format: format,
                               tags: tags, hasArtwork: hasPicture,
                               verifiedStamp: vorbis.first(IntegrityVerifier.verifiedFieldKey))
        }
        let format = try AudioProbe.probe(url)
        let full = (try? TagIO.read(url)) ?? TrackTags()
        return LibraryItem(relativePath: relativePath, fileSize: fileSize, modified: modified, format: format,
                           tags: full.withoutArtwork, hasArtwork: full.artwork != nil,
                           verifiedStamp: TagIO.verifiedStamp(url))
    }
}
