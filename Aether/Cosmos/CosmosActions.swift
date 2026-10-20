import AppKit
import Cosmos
import FlacKit
import Foundation
import TagKit

extension CosmosStore {
    func move(_ items: [LibraryItem], toFolder folder: String, undoManager: UndoManager?) async {
        await moveURLs(items.map(url(for:)), toFolder: folder, undoManager: undoManager)
    }

    func moveURLs(_ urls: [URL], toFolder folder: String, undoManager: UndoManager?) async {
        let target = root.appending(path: folder, directoryHint: .isDirectory)
        guard let moves = try? await Task.detached(operation: { try Organizer.move(urls, to: target) }).value, !moves.isEmpty else { return }
        await record(moves, reason: "move", actionName: "Mover a \(folder)", undoManager: undoManager)
    }

    func plannedRenames(for items: [LibraryItem]) async -> [FileMove] {
        let urls = items.map(url(for:))
        let tags = await loadFullTags(items)
        return Organizer.plannedRenames(Array(zip(urls, tags.map(\.withoutArtwork))))
    }

    func applyRenames(_ moves: [FileMove], undoManager: UndoManager?) async {
        guard let applied = try? await Task.detached(operation: { try Organizer.apply(moves) }).value else { return }
        await record(applied, reason: "rename", actionName: "Renombrar desde tags", undoManager: undoManager)
    }

    func trash(_ items: [LibraryItem], undoManager: UndoManager?) async {
        var moves: [FileMove] = []
        for url in items.map(url(for:)) {
            var resulting: NSURL?
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: &resulting)) != nil, let trashed = resulting as URL? {
                moves.append(FileMove(from: url, to: trashed))
            }
        }
        guard !moves.isEmpty else { return }
        await record(moves, reason: "trash", actionName: "Mover a la Papelera", undoManager: undoManager)
    }

    /// Re-verifies FLACs against their STREAMINFO MD5; stamps AETHER_VERIFIED when the file proves bit-perfect.
    func verify(_ items: [LibraryItem]) async -> [String: IntegrityReport] {
        let flacs = items.filter { $0.format.codec == .flac }
        verifying.formUnion(flacs.map(\.id))
        defer { verifying.subtract(flacs.map(\.id)) }
        var reports: [String: IntegrityReport] = [:]
        for item in flacs {
            let url = url(for: item)
            let report = await Task.detached(priority: .userInitiated) { () -> IntegrityReport? in
                guard let report = try? IntegrityVerifier.verify(flacAt: url) else { return nil }
                if report.verdict == .verified, let tags = try? FlacTags.read(url).tags {
                    try? FlacTags.write(tags, to: url, extraFields: [
                        IntegrityVerifier.verifiedFieldKey: IntegrityVerifier.verifiedFieldValue(report, at: .now)])
                }
                return report
            }.value
            reports[item.id] = report
        }
        await rescan()
        return reports
    }

    private func record(_ moves: [FileMove], reason: String, actionName: String, undoManager: UndoManager?) async {
        await journal.record(moves, reason: reason)
        onRelocated?(moves)
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in
                let inverse = moves.map(\.inverse).reversed()
                guard let undone = try? Organizer.apply(Array(inverse)) else { return }
                await store.record(undone, reason: "undo-\(reason)", actionName: actionName, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(actionName)
        await rescan()
    }
}
