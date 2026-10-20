import Foundation
import Testing
@testable import FlacKit
import TagKit

@Suite struct FlacFrameScannerTests {
    @Test(arguments: [16, 24])
    func cleanFileCountsEverySample(bits: Int) throws {
        let (url, pcm) = try AudioFixture.makeFLAC(seconds: 2.5, bits: bits)
        let report = try FlacFrameScanner.scan(fileAt: url, collectOffsets: true)
        #expect(report.isClean)
        #expect(report.samples == UInt64(pcm.count / (2 * bits / 8)))
        #expect(report.frames == report.frameOffsets?.count)
        #expect(report.frames > 1)
        #expect(report.minFrameSize > 0 && report.maxFrameSize >= report.minFrameSize)
    }

    @Test func detectsSingleFlippedByte() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 2.5)
        let clean = try FlacFrameScanner.scan(fileAt: url, collectOffsets: true)
        var bytes = [UInt8](try Data(contentsOf: url))
        let target = clean.frameOffsets![clean.frames / 2] + 40
        bytes[target] ^= 0x01
        try Data(bytes).write(to: url)
        let report = try FlacFrameScanner.scan(fileAt: url)
        #expect(!report.isClean)
        #expect(report.firstBadOffset == clean.frameOffsets![clean.frames / 2])
    }

    @Test func detectsTruncation() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 2.5)
        let bytes = [UInt8](try Data(contentsOf: url))
        try Data(bytes.dropLast(500)).write(to: url)
        #expect(!(try FlacFrameScanner.scan(fileAt: url).isClean))
    }

    @Test func reportsMonotonicProgress() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 4)
        let box = ProgressBox()
        _ = try FlacFrameScanner.scan(fileAt: url) { box.values.append($0) }
        #expect(!box.values.isEmpty)
        #expect(box.values == box.values.sorted())
        #expect(box.values.last == 1.0)
    }
}
