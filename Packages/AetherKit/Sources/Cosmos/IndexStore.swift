public import Foundation

public enum IndexStore {
    private struct Snapshot: Codable {
        var schema = 1
        var root: String
        var items: [LibraryItem]
    }

    public static func load(from file: URL, root: URL) -> [String: LibraryItem] {
        guard let data = try? Data(contentsOf: file),
              let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data),
              snapshot.schema == 1, snapshot.root == root.standardizedFileURL.path
        else { return [:] }
        return Dictionary(snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }

    public static func save(_ items: [LibraryItem], root: URL, to file: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Snapshot(root: root.standardizedFileURL.path, items: items)).write(to: file, options: .atomic)
    }
}
