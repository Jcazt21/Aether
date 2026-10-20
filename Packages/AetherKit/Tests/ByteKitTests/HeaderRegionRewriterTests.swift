import Foundation
import Testing
@testable import ByteKit

@Suite struct HeaderRegionRewriterTests {
    private func temp(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "hrr-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func sameLengthWritesInPlaceAndKeepsInode() throws {
        let url = try temp([1, 2, 3, 4, 9, 9, 9])
        let inodeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        try HeaderRegionRewriter.replace(fileAt: url, oldLength: 4, with: [5, 6, 7, 8])
        #expect(try [UInt8](Data(contentsOf: url)) == [5, 6, 7, 8, 9, 9, 9])
        let inodeAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        #expect(inodeBefore == inodeAfter)
    }

    @Test func differentLengthRewritesTail() throws {
        let tail = [UInt8](repeating: 7, count: 3_000_000)
        let url = try temp([1, 2] + tail)
        try HeaderRegionRewriter.replace(fileAt: url, oldLength: 2, with: [3, 4, 5, 6])
        let result = try [UInt8](Data(contentsOf: url))
        #expect(Array(result.prefix(4)) == [3, 4, 5, 6])
        #expect(result.count == 4 + tail.count)
        #expect(result.last == 7)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasSuffix(".aether-tmp") }
        #expect(leftovers.isEmpty)
    }
}
