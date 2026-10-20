import FlacKit
import Foundation
import TagKit
import Testing
@testable import AetherCore
import TestSupport

@Suite struct DashFlacStreamTests {
    @Test func decodesASegmentToTheRightFrameCount() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 2)
        let bytes = [UInt8](try Data(contentsOf: url))
        let si = try FlacMetadataIO.read(url).streamInfo()
        let scan = try FlacFrameScanner.scan(fileAt: url, collectOffsets: true)
        let offsets = scan.frameOffsets! + [bytes.count]
        let frames = (0..<10).map { Array(bytes[offsets[$0]..<offsets[$0 + 1]]) }
        let initSegment = MP4Fixture.initSegment(streamInfo: si)
        let decoder = try FlacPacketDecoder(config: try FMP4Flac.parseInit(initSegment),
                                            cookie: try StreamCookie.make(from: initSegment),
                                            maxPacketSize: frames.map(\.count).max()!)
        let pcm = try decoder.decode(segment: MP4Fixture.mediaSegment(frames: frames, duration: UInt32(si.maxBlockSize)))
        #expect(Int(pcm.frameLength) == 10 * Int(si.maxBlockSize))
    }
}
