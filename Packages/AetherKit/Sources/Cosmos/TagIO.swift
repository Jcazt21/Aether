import AudioToolbox
public import Foundation
public import TagKit

public enum TagIO {
    public static let supportedExtensions: Set<String> = ["flac", "mp3", "wav", "aiff", "aif", "m4a"]
    /// Flip to false if spike S3 shows rekordbox ignores ID3 chunks in WAV.
    nonisolated(unsafe) public static var wavTagsEnabled = true

    public static func isWritable(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "flac", "mp3", "aiff", "aif": true
        case "wav": wavTagsEnabled
        default: false
        }
    }

    public static func read(_ url: URL) throws -> TrackTags {
        switch url.pathExtension.lowercased() {
        case "flac": try FlacTags.read(url).tags
        case "mp3": try ID3FileIO.read(url)
        case "wav", "aiff", "aif": try ChunkID3IO.read(url)
        default: readInfoDictionary(url)
        }
    }

    public static func write(_ tags: TrackTags, to url: URL) throws {
        guard isWritable(url) else { throw CocoaError(.fileWriteNoPermission) }
        switch url.pathExtension.lowercased() {
        case "flac": try FlacTags.write(tags, to: url)
        case "mp3": try ID3FileIO.write(tags, to: url)
        default: try ChunkID3IO.write(tags, to: url)
        }
    }

    public static func verifiedStamp(_ url: URL) -> String? {
        guard url.pathExtension.lowercased() == "flac",
              let header = try? FlacMetadataIO.read(url),
              let block = header.blocks(ofType: FlacBlockType.vorbisComment).first,
              let vorbis = try? VorbisComment(payload: block.payload)
        else { return nil }
        return vorbis.first("AETHER_VERIFIED")
    }

    /// Read-only fallback (m4a): AudioToolbox info dictionary.
    private static func readInfoDictionary(_ url: URL) -> TrackTags {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let file = fileID else { return TrackTags() }
        defer { AudioFileClose(file) }
        var dict: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr,
              let info = dict?.takeRetainedValue() as? [String: Any] else { return TrackTags() }
        return TrackTags(title: info[kAFInfoDictionary_Title] as? String, artist: info[kAFInfoDictionary_Artist] as? String,
                         album: info[kAFInfoDictionary_Album] as? String, genre: info[kAFInfoDictionary_Genre] as? String,
                         year: info[kAFInfoDictionary_Year] as? String,
                         bpm: (info[kAFInfoDictionary_Tempo] as? String).flatMap(Double.init))
    }
}
