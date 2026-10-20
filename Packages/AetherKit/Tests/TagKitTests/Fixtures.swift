import Foundation
@testable import TagKit

enum Fixtures {
    static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "tagkit-\(UUID().uuidString).\(ext)")
    }

    static let streamInfo = StreamInfo(
        minBlockSize: 4096, maxBlockSize: 4096, minFrameSize: 14, maxFrameSize: 18_000,
        sampleRate: 96_000, channels: 2, bitsPerSample: 24, totalSamples: 10_418_594,
        md5: Array(0..<16))

    /// Fake FLAC: real metadata header followed by `audio` bytes standing in for frames.
    static func flacFile(blocks: [FlacBlock], audio: [UInt8] = Array(repeating: 0xAA, count: 4096)) throws -> URL {
        let url = tempURL("flac")
        try Data(try FlacMetadataIO.serialize(blocks) + audio).write(to: url)
        return url
    }

    static func bytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }
}
