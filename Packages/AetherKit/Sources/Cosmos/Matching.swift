import Foundation

public enum MatchKey {
    public static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }

    public static func primaryArtist(_ s: String) -> String {
        let cut = s.replacing(/(?i)\s*(,|&|\bfeat\.?|\bft\.?|\bx\b|\bvs\.?).*$/, with: "")
        return normalize(cut)
    }

    /// "(Original Mix)" is noise; any other version text is meaningful.
    public static func strict(artist: String, title: String) -> String {
        let t = title.replacing(/(?i)\s*[\(\[]original mix[\)\]]/, with: "")
        return "\(primaryArtist(artist))|\(normalize(t))"
    }

    /// Ignores every parenthetical/bracketed version: "Dreams (Extended Mix)" ~ "Dreams".
    public static func loose(artist: String, title: String) -> String {
        let t = title.replacing(/\s*[\(\[][^\)\]]*[\)\]]/, with: "")
        return "\(primaryArtist(artist))|\(normalize(t))"
    }
}

public struct DuplicateGroup: Identifiable, Sendable, Equatable {
    public var id: String
    public var itemIDs: [String]

    public init(id: String, itemIDs: [String]) {
        self.id = id
        self.itemIDs = itemIDs
    }
}

public enum DuplicateDetector {
    public static func groups(in items: [LibraryItem]) -> [DuplicateGroup] {
        let keyed = items.compactMap { item -> (String, String)? in
            guard !item.displayArtist.isEmpty else { return nil }
            return (MatchKey.strict(artist: item.displayArtist, title: item.displayTitle), item.id)
        }
        return Dictionary(grouping: keyed, by: \.0)
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(id: $0.key, itemIDs: $0.value.map(\.1).sorted()) }
            .sorted { $0.id < $1.id }
    }
}

public struct MasterLookup: Sendable {
    public enum Match: Equatable, Sendable {
        case exact(LibraryItem)
        case similar(LibraryItem)
    }

    public static let empty = MasterLookup(items: [])

    public let items: [LibraryItem]
    private let byISRC: [String: Int]
    private let byStrict: [String: Int]
    private let byLoose: [String: Int]

    public init(items: [LibraryItem]) {
        self.items = items
        var isrc: [String: Int] = [:], strict: [String: Int] = [:], loose: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            if let code = item.tags.isrc?.uppercased() { isrc[code] = isrc[code] ?? index }
            guard !item.displayArtist.isEmpty else { continue }
            strict[MatchKey.strict(artist: item.displayArtist, title: item.displayTitle)] = index
            loose[MatchKey.loose(artist: item.displayArtist, title: item.displayTitle)] = index
        }
        byISRC = isrc
        byStrict = strict
        byLoose = loose
    }

    public func match(isrc: String?, artist: String, title: String) -> Match? {
        if let code = isrc?.uppercased(), let i = byISRC[code] { return .exact(items[i]) }
        if let i = byStrict[MatchKey.strict(artist: artist, title: title)] { return .exact(items[i]) }
        if let i = byLoose[MatchKey.loose(artist: artist, title: title)] { return .similar(items[i]) }
        return nil
    }
}
