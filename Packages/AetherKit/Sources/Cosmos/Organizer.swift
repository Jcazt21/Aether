public import Foundation
public import TagKit

public struct FileMove: Codable, Sendable, Equatable {
    public var from: URL
    public var to: URL

    public init(from: URL, to: URL) {
        self.from = from
        self.to = to
    }

    public var inverse: FileMove { FileMove(from: to, to: from) }
}

public enum Organizer {
    /// Same-volume renames: instantaneous, no copy. Never overwrites.
    public static func move(_ urls: [URL], to folder: URL) throws -> [FileMove] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var done: [FileMove] = []
        do {
            for url in urls where url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
                let base = url.deletingPathExtension().lastPathComponent
                let target = FileNaming.uniqueURL(in: folder, baseName: base, extension: url.pathExtension)
                try FileManager.default.moveItem(at: url, to: target)
                done.append(FileMove(from: url, to: target))
            }
        } catch {
            _ = try? apply(done.map(\.inverse).reversed())   // all-or-nothing
            throw error
        }
        return done
    }

    @discardableResult
    public static func apply(_ moves: some Sequence<FileMove>) throws -> [FileMove] {
        var applied: [FileMove] = []
        for move in moves {
            try FileManager.default.moveItem(at: move.from, to: move.to)
            applied.append(move)
        }
        return applied
    }

    /// Preview for "Rename from tags": `{artist} - {title}.{ext}`; skips untagged and already-correct files.
    public static func plannedRenames(_ files: [(url: URL, tags: TrackTags)]) -> [FileMove] {
        var claimed = Set<String>()
        var plan: [FileMove] = []
        for (url, tags) in files {
            guard let artist = tags.artist, let title = tags.title else { continue }
            let base = FileNaming.baseName(artist: artist, title: title, fallback: "")
            let folder = url.deletingLastPathComponent()
            if url.deletingPathExtension().lastPathComponent == base { continue }
            var candidate = folder.appending(path: "\(base).\(url.pathExtension)")
            var counter = 2
            while FileManager.default.fileExists(atPath: candidate.path) || claimed.contains(candidate.path) {
                candidate = folder.appending(path: "\(base) (\(counter)).\(url.pathExtension)")
                counter += 1
            }
            claimed.insert(candidate.path)
            plan.append(FileMove(from: url, to: candidate))
        }
        return plan
    }
}

/// Append-only audit log of every move/rename: the source of truth for relocating tracks in rekordbox.
public actor MoveJournal {
    private struct Line: Encodable { let date: Date; let reason: String; let from: String; let to: String }
    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func record(_ moves: [FileMove], reason: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let now = Date()
        let text = moves.compactMap { move -> String? in
            let line = Line(date: now, reason: reason, from: move.from.path, to: move.to.path)
            return (try? encoder.encode(line)).flatMap { String(data: $0, encoding: .utf8) }
        }.map { $0 + "\n" }.joined()
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL)
        }
    }
}
