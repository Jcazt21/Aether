public import FlacKit
public import Foundation

/// Persists download checkpoints so an interrupted `.aether-part` resumes instead of restarting.
public actor CheckpointStore {
    private let fileURL: URL
    private var checkpoints: [UUID: AssemblerCheckpoint]
    private var unsaved = 0

    public init(fileURL: URL) {
        self.fileURL = fileURL
        checkpoints = (try? JSONDecoder().decode([UUID: AssemblerCheckpoint].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    public func checkpoint(for id: UUID) -> AssemblerCheckpoint? { checkpoints[id] }

    public func save(_ checkpoint: AssemblerCheckpoint, for id: UUID) {
        checkpoints[id] = checkpoint
        unsaved += 1
        if unsaved >= 5 { persist() }
    }

    public func remove(_ id: UUID) {
        guard checkpoints.removeValue(forKey: id) != nil else { return }
        persist()
    }

    private func persist() {
        unsaved = 0
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(checkpoints).write(to: fileURL, options: .atomic)
    }
}
