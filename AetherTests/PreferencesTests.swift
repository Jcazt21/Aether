import Foundation
import Testing
@testable import Aether

@MainActor
@Suite struct PreferencesTests {
    private func freshDefaults() -> UserDefaults {
        let name = "aether-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsMatchSpec() {
        let p = Preferences(defaults: freshDefaults())
        #expect(p.masterFolder == URL.homeDirectory.appending(path: "Master"))
        #expect(p.inboxFolderName == "Inbox")
        #expect(p.inboxFolder == URL.homeDirectory.appending(path: "Master/Inbox"))
        #expect(p.hifiBaseURL == URL(string: "http://127.0.0.1:8000")!)
        #expect(p.qualityPolicyRaw == "hiResCapped96")
        #expect(p.maxConcurrentDownloads == 3)
        #expect(p.bitPerfect)
        #expect(p.rekordboxXMLEnabled)
        #expect(p.rekordboxXMLURL == URL.homeDirectory.appending(path: "Music/Aether/rekordbox.xml"))
    }

    @Test func persistsChanges() {
        let d = freshDefaults()
        let p = Preferences(defaults: d)
        p.maxConcurrentDownloads = 2
        p.masterFolder = URL(filePath: "/tmp/Master")
        let reloaded = Preferences(defaults: d)
        #expect(reloaded.maxConcurrentDownloads == 2)
        #expect(reloaded.masterFolder == URL(filePath: "/tmp/Master"))
    }

    @Test func clampsConcurrency() {
        let p = Preferences(defaults: freshDefaults())
        p.maxConcurrentDownloads = 9
        #expect(p.maxConcurrentDownloads == 4)
        p.maxConcurrentDownloads = 0
        #expect(p.maxConcurrentDownloads == 1)
    }
}
