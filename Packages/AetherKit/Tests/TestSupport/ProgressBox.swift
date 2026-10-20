import Synchronization

public final class ProgressBox: Sendable {
    private let storage = Mutex<[Double]>([])
    public init() {}
    public var values: [Double] {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
