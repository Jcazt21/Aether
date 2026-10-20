public import Foundation

/// rekordbox "rekordbox xml" import format. Jean points rekordbox › Preferences › Advanced › rekordbox xml
/// at this file once; Harvester downloads then appear under Harvester › <day> playlists.
public enum RekordboxXML {
    public static func location(_ url: URL) -> String {
        let path = url.path(percentEncoded: false).precomposedStringWithCanonicalMapping
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "file://localhost" + encoded
    }

    public static func document(entries: [HistoryEntry], calendar: Calendar = .current) -> String {
        let ordered = entries.sorted { $0.finishedAt < $1.finishedAt }
        var ids: [UUID: Int] = [:]
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        xml += #"<DJ_PLAYLISTS Version="1.0.0">"# + "\n"
        xml += #"  <PRODUCT Name="Aether" Version="1.0" Company="Aether"/>"# + "\n"
        xml += #"  <COLLECTION Entries="\#(ordered.count)">"# + "\n"
        for (index, entry) in ordered.enumerated() {
            let id = index + 1
            ids[entry.id] = id
            let bitRate = entry.format.duration > 0 ? Int(Double(entry.bytes) * 8 / entry.format.duration / 1000) : 0
            let attributes: [(String, String)] = [
                ("TrackID", "\(id)"), ("Name", entry.title), ("Artist", entry.artist), ("Album", entry.album ?? ""),
                ("Genre", entry.genre ?? ""), ("Kind", "FLAC File"), ("Size", "\(entry.bytes)"),
                ("TotalTime", "\(Int(entry.format.duration))"), ("SampleRate", "\(entry.format.sampleRate)"),
                ("BitRate", "\(bitRate)"), ("DateAdded", day(entry.finishedAt, calendar)),
                ("Location", location(entry.fileURL)),
            ]
            xml += "    <TRACK " + attributes.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: " ") + "/>\n"
        }
        xml += "  </COLLECTION>\n"

        let byDay = Dictionary(grouping: ordered) { day($0.finishedAt, calendar) }
        let days = byDay.keys.sorted(by: >)
        xml += "  <PLAYLISTS>\n"
        xml += #"    <NODE Type="0" Name="ROOT" Count="1">"# + "\n"
        xml += #"      <NODE Type="0" Name="Harvester" Count="\#(days.count)">"# + "\n"
        for key in days {
            let items = byDay[key]!
            xml += #"        <NODE Type="1" Name="\#(key)" KeyType="0" Entries="\#(items.count)">"# + "\n"
            for item in items { xml += #"          <TRACK Key="\#(ids[item.id]!)"/>"# + "\n" }
            xml += "        </NODE>\n"
        }
        xml += "      </NODE>\n    </NODE>\n  </PLAYLISTS>\n</DJ_PLAYLISTS>\n"
        return xml
    }

    public static func write(entries: [HistoryEntry], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(document(entries: entries).utf8).write(to: url, options: .atomic)
    }

    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
