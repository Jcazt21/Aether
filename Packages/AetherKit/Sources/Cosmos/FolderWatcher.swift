import CoreServices
public import Foundation

/// Recursive directory watcher. Directory-level FSEvents are enough: any event triggers an incremental
/// rescan, which is cheap thanks to the (size, mtime) reuse in LibraryScanner.
public final class FolderWatcher: @unchecked Sendable {
    private final class Box {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }

    public let changes: AsyncStream<Void>
    private var stream: FSEventStreamRef?
    private let continuation: AsyncStream<Void>.Continuation

    public init?(url: URL, latency: TimeInterval = 1.0) {
        (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let box = Unmanaged.passRetained(Box(continuation))
        var context = FSEventStreamContext(
            version: 0, info: box.toOpaque(), retain: nil,
            release: { info in if let info { Unmanaged<Box>.fromOpaque(info).release() } },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().continuation.yield()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        else {
            box.release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.jazar.Aether.fsevents", qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        continuation.finish()
    }

    deinit { stop() }
}
