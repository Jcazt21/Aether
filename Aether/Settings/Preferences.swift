import Foundation
import Observation
import TagKit

@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let master = "masterFolder"
        static let inbox = "inboxFolderName"
        static let hifi = "hifiBaseURL"
        static let quality = "qualityPolicy"
        static let concurrency = "maxConcurrentDownloads"
        static let bitPerfect = "bitPerfect"
        static let xmlEnabled = "rekordboxXMLEnabled"
        static let xmlURL = "rekordboxXMLURL"
        static let filenameTemplate = "filenameTemplate"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var masterFolder: URL { didSet { defaults.set(masterFolder.path, forKey: Key.master) } }
    var inboxFolderName: String { didSet { defaults.set(inboxFolderName, forKey: Key.inbox) } }
    var hifiBaseURL: URL { didSet { defaults.set(hifiBaseURL.absoluteString, forKey: Key.hifi) } }
    /// Raw value of `Harvester.QualityPolicy` (plan 04): "hiResCapped96" | "hiRes" | "lossless".
    var qualityPolicyRaw: String { didSet { defaults.set(qualityPolicyRaw, forKey: Key.quality) } }
    var maxConcurrentDownloads: Int {
        didSet {
            let clamped = min(max(maxConcurrentDownloads, 1), 4)
            if clamped != maxConcurrentDownloads { maxConcurrentDownloads = clamped; return }
            defaults.set(maxConcurrentDownloads, forKey: Key.concurrency)
        }
    }
    var bitPerfect: Bool { didSet { defaults.set(bitPerfect, forKey: Key.bitPerfect) } }
    var rekordboxXMLEnabled: Bool { didSet { defaults.set(rekordboxXMLEnabled, forKey: Key.xmlEnabled) } }
    var rekordboxXMLURL: URL { didSet { defaults.set(rekordboxXMLURL.path, forKey: Key.xmlURL) } }

    var filenameTemplate: String { didSet { defaults.set(filenameTemplate, forKey: Key.filenameTemplate) } }

    var inboxFolder: URL { masterFolder.appending(path: inboxFolderName) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let home = URL.homeDirectory
        masterFolder = defaults.string(forKey: Key.master).map { URL(filePath: $0) } ?? home.appending(path: "Master")
        inboxFolderName = defaults.string(forKey: Key.inbox) ?? "Por clasificar"
        hifiBaseURL = defaults.string(forKey: Key.hifi).flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:8000")!
        qualityPolicyRaw = defaults.string(forKey: Key.quality) ?? "hiResCapped96"
        let storedConcurrency = defaults.integer(forKey: Key.concurrency)
        maxConcurrentDownloads = storedConcurrency == 0 ? 3 : min(max(storedConcurrency, 1), 4)
        bitPerfect = defaults.object(forKey: Key.bitPerfect) as? Bool ?? true
        rekordboxXMLEnabled = defaults.object(forKey: Key.xmlEnabled) as? Bool ?? true
        filenameTemplate = defaults.string(forKey: Key.filenameTemplate) ?? FileNaming.defaultTemplate
        rekordboxXMLURL = defaults.string(forKey: Key.xmlURL).map { URL(filePath: $0) }
            ?? home.appending(path: "Music/Aether/rekordbox.xml")
    }
}
