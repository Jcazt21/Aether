public import Foundation

public enum FileNaming {
    private static let maxUTF8 = 200

    public static func sanitize(_ s: String) -> String {
        var out = s
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        while out.hasSuffix(".") { out.removeLast() }
        out = out.trimmingCharacters(in: .whitespaces)
        while out.utf8.count > maxUTF8 { out.removeLast() }
        return out
    }

    public static func titleWithVersion(_ title: String, version: String?) -> String {
        guard let version = version?.trimmingCharacters(in: .whitespaces), !version.isEmpty,
              title.range(of: version, options: .caseInsensitive) == nil
        else { return title }
        return "\(title) (\(version))"
    }

    public static func baseName(artist: String?, title: String?, fallback: String) -> String {
        let a = artist.map(sanitize).flatMap { $0.isEmpty ? nil : $0 }
        let t = title.map(sanitize).flatMap { $0.isEmpty ? nil : $0 }
        switch (a, t) {
        case let (a?, t?): return "\(a) - \(t)"
        case let (nil, t?): return t
        case let (a?, nil): return a
        case (nil, nil):
            let f = sanitize(fallback)
            return f.isEmpty ? "Sin título" : f
        }
    }

    public static let defaultTemplate = "{artist} - {title}"

    /// Fills `{discNumber}`, `{trackNumber}`, `{artist}`, `{title}`, `{album}`; each value is sanitized. Empty result → nil.
    public static func render(template: String, discNumber: Int?, trackNumber: Int?,
                              artist: String?, title: String?, album: String?) -> String? {
        let values: [String: String] = [
            "{discNumber}": discNumber.map(String.init) ?? "",
            "{trackNumber}": trackNumber.map { String(format: "%02d", $0) } ?? "",
            "{artist}": artist.map(sanitize) ?? "",
            "{title}": title.map(sanitize) ?? "",
            "{album}": album.map(sanitize) ?? "",
        ]
        var out = template
        for (key, value) in values { out = out.replacingOccurrences(of: key, with: value) }
        out = sanitize(out.replacingOccurrences(of: "\\", with: "-"))
        return out.isEmpty ? nil : out
    }

    public static func uniqueURL(in folder: URL, baseName: String, extension ext: String,
                                 fileManager: FileManager = .default) -> URL {
        var candidate = folder.appending(path: "\(baseName).\(ext)")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(baseName) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }
}
