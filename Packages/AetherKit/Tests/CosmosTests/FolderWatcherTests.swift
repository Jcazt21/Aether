import Foundation
import Testing
@testable import Cosmos

@Suite struct FolderWatcherTests {
    @Test(.timeLimit(.minutes(1)))
    func signalsWhenAFileAppears() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "UK House"), withIntermediateDirectories: true)
        let watcher = try #require(FolderWatcher(url: dir, latency: 0.1))
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try Data([1]).write(to: dir.appending(path: "UK House/new.flac"))
        var iterator = watcher.changes.makeAsyncIterator()
        let signal: Void? = await iterator.next()
        #expect(signal != nil)
    }
}
