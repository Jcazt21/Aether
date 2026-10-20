import CryptoKit
import Foundation
import Testing
@testable import FlacKit
import TestSupport

@Suite struct PCMDigestTests {
    @Test(arguments: [16, 24])
    func md5MatchesSourcePCM(bits: Int) throws {
        let (url, pcm) = try AudioFixture.makeFLAC(seconds: 1.5, bits: bits)
        let result = try PCMDigest.md5(ofFileAt: url, bitsPerSample: bits, channels: 2)
        #expect(result.md5 == Array(Insecure.MD5.hash(data: pcm)))
        #expect(result.frames == UInt64(pcm.count / (2 * bits / 8)))
    }

    @Test func reportsProgressToCompletion() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 3)
        let box = ProgressBox()
        _ = try PCMDigest.md5(ofFileAt: url, bitsPerSample: 16, channels: 2, totalFrames: 132_300) { box.values.append($0) }
        #expect(box.values.last == 1.0)
        #expect(box.values == box.values.sorted())
    }

    @Test func rejectsOddBitDepth() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 0.1)
        #expect(throws: PCMDigestError.unsupportedBitDepth(20)) {
            try PCMDigest.md5(ofFileAt: url, bitsPerSample: 20, channels: 2)
        }
    }
}
