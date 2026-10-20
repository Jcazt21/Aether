import AudioToolbox
import Foundation
import Testing
@testable import Cosmos
import TagKit
import TestSupport

@Suite struct LibraryScannerTests {
    private func makeMaster() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "Master-\(UUID().uuidString)")
        let fm = FileManager.default
        for folder in ["UK House", "Tech House", "Por clasificar", "Vacía"] {
            try fm.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        let (a, _) = try AudioFixture.makeFLAC(seconds: 0.5)
        try fm.copyItem(at: a, to: root.appending(path: "UK House/Prospa - Dreams.flac"))
        try fm.copyItem(at: a, to: root.appending(path: "Tech House/PAWSA - The Groovy Cat.flac"))
        try fm.copyItem(at: AudioFixture.makePCMFile(type: kAudioFileWAVEType, ext: "wav"), to: root.appending(path: "b2bsept.wav"))
        try Data().write(to: root.appending(path: "UK House/.Prospa - Dreams.flac.aether-part"))
        try Data("x".utf8).write(to: root.appending(path: "UK House/notes.txt"))
        return root
    }

    @Test func coldScanFindsAudioAndFolders() async throws {
        let root = try makeMaster()
        let result = await LibraryScanner.scan(root: root, previous: [:])
        #expect(Set(result.items.map(\.relativePath)) == ["UK House/Prospa - Dreams.flac", "Tech House/PAWSA - The Groovy Cat.flac", "b2bsept.wav"])
        #expect(result.folders == ["Por clasificar", "Tech House", "UK House", "Vacía"])
        #expect(result.read == 3)
        #expect(result.reused == 0)
    }

    @Test func warmScanReusesUnchangedAndRereadsModified() async throws {
        let root = try makeMaster()
        let first = await LibraryScanner.scan(root: root, previous: [:])
        let previous = Dictionary(uniqueKeysWithValues: first.items.map { ($0.id, $0) })
        let changed = root.appending(path: "UK House/Prospa - Dreams.flac")
        try FlacTags.write(TrackTags(title: "Dreams", artist: "Prospa", bpm: 126), to: changed)
        let second = await LibraryScanner.scan(root: root, previous: previous)
        #expect(second.reused == 2)
        #expect(second.read == 1)
        #expect(second.items.first { $0.id == "UK House/Prospa - Dreams.flac" }?.bpmValue == 126)
    }

    @Test func indexRoundTripsAndIgnoresOtherRoots() async throws {
        let root = try makeMaster()
        let result = await LibraryScanner.scan(root: root, previous: [:])
        let file = FileManager.default.temporaryDirectory.appending(path: "index-\(UUID().uuidString).plist")
        try IndexStore.save(result.items, root: root, to: file)
        #expect(IndexStore.load(from: file, root: root).count == 3)
        #expect(IndexStore.load(from: file, root: URL(filePath: "/elsewhere")).isEmpty)
    }
}
