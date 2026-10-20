import FlacKit
public import Foundation

public actor HarvestEngine {
    public nonisolated let events: AsyncStream<HarvestEvent>
    private let continuation: AsyncStream<HarvestEvent>.Continuation
    private var pipeline: HarvestPipeline
    private let checkpoints: CheckpointStore?
    private var maxConcurrent: Int
    private var queue: [HarvestRequest] = []
    private var running: [UUID: (request: HarvestRequest, task: Task<Void, Never>)] = [:]

    public init(pipeline: HarvestPipeline, checkpoints: CheckpointStore?, maxConcurrent: Int = 3) {
        (events, continuation) = AsyncStream.makeStream(of: HarvestEvent.self, bufferingPolicy: .bufferingNewest(512))
        self.pipeline = pipeline
        self.checkpoints = checkpoints
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public var activeCount: Int { running.count }
    /// Queued + running, oldest first — what must be restored after a relaunch.
    public var pendingRequests: [HarvestRequest] { running.values.map(\.request).sorted { $0.createdAt < $1.createdAt } + queue }

    public func setMaxConcurrent(_ value: Int) {
        maxConcurrent = min(max(value, 1), 4)
        pump()
    }

    public func setPipeline(_ pipeline: HarvestPipeline) { self.pipeline = pipeline }

    public func enqueue(_ requests: [HarvestRequest]) {
        for request in requests {
            queue.append(request)
            continuation.yield(HarvestEvent(id: request.id, phase: .queued))
        }
        pump()
    }

    public func cancel(_ id: UUID) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index)
            continuation.yield(HarvestEvent(id: id, phase: .cancelled))
        }
        running[id]?.task.cancel()
    }

    public func cancelAll() {
        for request in queue { continuation.yield(HarvestEvent(id: request.id, phase: .cancelled)) }
        queue.removeAll()
        running.values.forEach { $0.task.cancel() }
    }

    private func pump() {
        while running.count < maxConcurrent, !queue.isEmpty {
            let request = queue.removeFirst()
            let pipeline = pipeline
            let checkpoints = checkpoints
            let continuation = continuation
            let task = Task.detached(priority: .utility) {
                await Self.run(request, pipeline: pipeline, checkpoints: checkpoints, continuation: continuation)
                await self.finished(request.id)
            }
            running[request.id] = (request, task)
        }
    }

    private func finished(_ id: UUID) {
        running[id] = nil
        pump()
    }

    private static func run(_ request: HarvestRequest, pipeline: HarvestPipeline, checkpoints: CheckpointStore?,
                            continuation: AsyncStream<HarvestEvent>.Continuation) async {
        let id = request.id
        let emit: @Sendable (HarvestPhase) -> Void = { continuation.yield(HarvestEvent(id: id, phase: $0)) }
        let save: @Sendable (AssemblerCheckpoint) -> Void = { c in Task { await checkpoints?.save(c, for: id) } }
        for attempt in 0..<2 {
            do {
                let resume = attempt == 0 ? await checkpoints?.checkpoint(for: id) : nil
                let result = try await pipeline.execute(request, resume: resume, checkpoint: save, emit: emit)
                await checkpoints?.remove(id)
                emit(.verified(result))
                return
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: HarvestPipeline.partURL(for: request))
                await checkpoints?.remove(id)
                emit(.cancelled)
                return
            } catch HarvestError.integrity where attempt == 0 {
                await checkpoints?.remove(id)   // one automatic full retry from scratch
                continue
            } catch {
                await checkpoints?.remove(id)
                emit(.failed(Self.message(for: error)))
                return
            }
        }
    }

    public static func message(for error: any Error) -> String {
        switch error {
        case HarvestError.integrity(let reason): "Integridad: \(reason)"
        case HarvestError.http(let code): "HTTP \(code)"
        case let error as URLError where error.code == .notConnectedToInternet: "Sin conexión"
        case let error as URLError where error.code == .cannotConnectToHost: "hifi-api no responde"
        default: String(describing: error)
        }
    }
}
