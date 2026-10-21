import Foundation
import Testing
@testable import TagKit

@Suite struct FileNamingTests {
    @Test func sanitizeRemovesPathSeparatorsAndTrims() {
        #expect(FileNaming.sanitize("AC/DC: Live  ") == "AC-DC- Live")
        #expect(FileNaming.sanitize("  Can't Decide (Extended) ") == "Can't Decide (Extended)")
        #expect(FileNaming.sanitize("trailing dots...") == "trailing dots")
        #expect(FileNaming.sanitize("tab\tand\nnewline") == "tab and newline")
    }

    @Test func sanitizeLimitsUTF8Length() {
        let long = String(repeating: "ñ", count: 300)
        #expect(FileNaming.sanitize(long).utf8.count <= 200)
    }

    @Test func titleWithVersion() {
        #expect(FileNaming.titleWithVersion("Dreams", version: "Extended Mix") == "Dreams (Extended Mix)")
        #expect(FileNaming.titleWithVersion("Dreams (Extended Mix)", version: "Extended Mix") == "Dreams (Extended Mix)")
        #expect(FileNaming.titleWithVersion("Dreams", version: nil) == "Dreams")
        #expect(FileNaming.titleWithVersion("Dreams", version: "  ") == "Dreams")
    }

    @Test func baseNameMatchesMasterConvention() {
        #expect(FileNaming.baseName(artist: "Prospa", title: "Dreams", fallback: "x") == "Prospa - Dreams")
        #expect(FileNaming.baseName(artist: nil, title: "Dreams", fallback: "x") == "Dreams")
        #expect(FileNaming.baseName(artist: nil, title: nil, fallback: "track-1") == "track-1")
    }

    @Test func uniqueURLAddsCounter() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = FileNaming.uniqueURL(in: folder, baseName: "Prospa - Dreams", extension: "flac")
        #expect(first.lastPathComponent == "Prospa - Dreams.flac")
        try Data().write(to: first)
        let second = FileNaming.uniqueURL(in: folder, baseName: "Prospa - Dreams", extension: "flac")
        #expect(second.lastPathComponent == "Prospa - Dreams (2).flac")
    }
}

@Suite struct FileNamingTemplateTests {
    @Test func rendersPlaceholders() {
        #expect(FileNaming.render(template: "{title} - {artist}", discNumber: 1, trackNumber: 3,
                                  artist: "Prospa", title: "Dreams", album: "LP") == "Dreams - Prospa")
        #expect(FileNaming.render(template: "{discNumber}-{trackNumber} {artist}/{album}", discNumber: 2, trackNumber: 3,
                                  artist: "AC/DC", title: nil, album: "LP") == "2-03 AC-DC-LP")
        #expect(FileNaming.render(template: "{album}", discNumber: nil, trackNumber: nil,
                                  artist: nil, title: nil, album: nil) == nil)
    }
}
