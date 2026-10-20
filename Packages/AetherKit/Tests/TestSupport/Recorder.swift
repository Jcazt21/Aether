import Synchronization

public final class Recorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])
    public init() {}
    public func append(_ value: Value) { storage.withLock { $0.append(value) } }
    public var values: [Value] { storage.withLock { $0 } }
}

public final class Counter: Sendable {
    private let storage = Mutex(0)
    public init() {}
    @discardableResult public func increment() -> Int { storage.withLock { $0 += 1; return $0 } }
    public var value: Int { storage.withLock { $0 } }
}
