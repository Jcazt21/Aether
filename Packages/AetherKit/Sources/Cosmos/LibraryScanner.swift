public import Foundation
import OSLog

public struct ScanResult: Sendable {
    public var items: [LibraryItem]
    public var folders: [String]
    public var reused: Int
    public var read: Int
    public var failures: [String: String]
}

public enum LibraryScanner {
    private static let signposter = OSSignposter(subsystem: "com.jazar.Aether", category: "cosmos")

    private struct Entry: Sendable {
        let url: URL
        let relativePath: String
        let size: Int64
        let modified: Date
        let added: Date
    }

    /// Stat-only pass decides what to re-read; only new/changed files are parsed, with bounded concurrency.
    @concurrent
    public static func scan(root: URL, previous: [String: LibraryItem], maxConcurrent: Int = 4) async -> ScanResult {
        let interval = signposter.beginInterval("scan", id: signposter.makeSignpostID())
        defer { signposter.endInterval("scan", interval) }

        let (entries, folders) = list(root: root)
        var items: [LibraryItem] = []
        var pending: [Entry] = []
        for entry in entries {
            if var old = previous[entry.relativePath], old.fileSize == entry.size, old.modified == entry.modified {
                old.added = entry.added
                items.append(old)
            } else {
                pending.append(entry)
            }
        }
        let reused = items.count
        var failures: [String: String] = [:]

        await withTaskGroup(of: (String, Result<LibraryItem, any Error>).self) { group in
            var iterator = pending.makeIterator()
            func addNext() {
                guard let entry = iterator.next() else { return }
                group.addTask {
                    (entry.relativePath, Result {
                        var item = try ItemReader.read(url: entry.url, relativePath: entry.relativePath, fileSize: entry.size, modified: entry.modified)
                        item.added = entry.added
                        return item
                    })
                }
            }
            for _ in 0..<maxConcurrent { addNext() }
            for await (path, result) in group {
                switch result {
                case .success(let item): items.append(item)
                case .failure(let error): failures[path] = String(describing: error)
                }
                addNext()
            }
        }
        items.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return ScanResult(items: items, folders: folders, reused: reused, read: pending.count - failures.count, failures: failures)
    }

    /// Synchronous on purpose: NSDirectoryEnumerator iteration is unavailable in async contexts.
    private static func list(root: URL) -> ([Entry], [String]) {
        let resolvedRoot = root.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path(percentEncoded: false).replacing(/\/+$/, with: "")
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey]
        guard let enumerator = FileManager.default.enumerator(at: resolvedRoot, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return ([], []) }
        var entries: [Entry] = []
        var folders: [String] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let fullPath = url.resolvingSymlinksInPath().path(percentEncoded: false).replacing(/\/+$/, with: "")
            guard fullPath.count > rootPath.count + 1 else { continue }
            let relative = String(fullPath.dropFirst(rootPath.count + 1))
            if values.isDirectory == true {
                if !relative.contains("/") { folders.append(relative) }
                continue
            }
            guard values.isRegularFile == true, TagIO.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            entries.append(Entry(url: url, relativePath: relative, size: Int64(values.fileSize ?? 0),
                                 modified: values.contentModificationDate ?? .distantPast,
                                 added: values.addedToDirectoryDate ?? values.contentModificationDate ?? .distantPast))
        }
        folders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return (entries, folders)
    }
}
