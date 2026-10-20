public import Foundation
import ByteKit

extension FileHandle {
    /// Reads exactly `count` bytes or throws `ByteError.outOfBounds`.
    public func readExactly(_ count: Int) throws -> [UInt8] {
        if count == 0 { return [] }
        guard let data = try read(upToCount: count), data.count == count else {
            throw ByteError.outOfBounds(offset: Int((try? offset()) ?? 0), needed: count)
        }
        return [UInt8](data)
    }
}
