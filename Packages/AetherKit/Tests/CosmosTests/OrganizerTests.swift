import Foundation
import Testing
@testable import Cosmos
import TagKit

@Suite struct OrganizerTests {
    private func tree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "org-\(UUID().uuidString)")
        for folder in ["Inbox", "UK House"] {
            try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        try Data([1]).write(to: root.appending(path: "Inbox/Prospa - Dreams.flac"))
        try Data([2]).write(to: root.appending(path: "UK House/Prospa - Dreams.flac"))
        return root
    }

    @Test func moveAvoidsCollisionsAndUndoRestores() throws {
        let root = try tree()
        let source = root.appending(path: "Inbox/Prospa - Dreams.flac")
        let moves = try Organizer.move([source], to: root.appending(path: "UK House"))
        #expect(moves.first?.to.lastPathComponent == "Prospa - Dreams (2).flac")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        _ = try Organizer.apply(moves.map(\.inverse).reversed())
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: source) == Data([1]))
    }

    @Test func plannedRenamesSkipUnchangedAndUntagged() throws {
        let root = try tree()
        let tagged = root.appending(path: "UK House/Prospa - Dreams.flac")
        let other = root.appending(path: "Inbox/Prospa - Dreams.flac")
        let plan = Organizer.plannedRenames([
            (tagged, TrackTags(title: "Dreams", artist: "Prospa")),
            (other, TrackTags(title: "Dreams (Extended Mix)", artist: "Prospa")),
            (other, TrackTags()),
        ])
        #expect(plan == [FileMove(from: other, to: root.appending(path: "Inbox/Prospa - Dreams (Extended Mix).flac"))])
    }

    @Test func journalAppendsJSONLines() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "journal-\(UUID().uuidString).jsonl")
        let journal = MoveJournal(fileURL: file)
        await journal.record([FileMove(from: URL(filePath: "/a"), to: URL(filePath: "/b"))], reason: "move")
        await journal.record([FileMove(from: URL(filePath: "/b"), to: URL(filePath: "/a"))], reason: "undo")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[1].contains("\"undo\""))
    }
}
