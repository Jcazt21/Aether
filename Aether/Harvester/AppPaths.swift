import Foundation

nonisolated enum AppPaths {
    static var support: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Aether", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var queue: URL { support.appending(path: "harvester-queue.json") }
    static var history: URL { support.appending(path: "harvester-history.json") }
    static var checkpoints: URL { support.appending(path: "harvester-checkpoints.json") }
    static var index: URL { support.appending(path: "cosmos-index.plist") }
    static var moveJournal: URL { support.appending(path: "cosmos-moves.jsonl") }
}
