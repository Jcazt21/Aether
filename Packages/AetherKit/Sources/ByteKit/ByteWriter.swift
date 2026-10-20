/// Append-only byte buffer builder.
public struct ByteWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init(reservingCapacity capacity: Int = 0) { bytes.reserveCapacity(capacity) }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16BE(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(truncatingIfNeeded: v)] }
    public mutating func u24BE(_ v: UInt32) {
        bytes += [UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }
    public mutating func u32BE(_ v: UInt32) {
        bytes += [UInt8(v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }
    public mutating func u64BE(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(shift))) }
    }
    public mutating func u16LE(_ v: UInt16) { bytes += [UInt8(truncatingIfNeeded: v), UInt8(v >> 8)] }
    public mutating func u32LE(_ v: UInt32) {
        bytes += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16), UInt8(v >> 24)]
    }
    public mutating func syncsafe32(_ v: UInt32) {
        bytes += [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
    }
    public mutating func append(_ other: some Sequence<UInt8>) { bytes.append(contentsOf: other) }
    public mutating func ascii(_ s: String) { bytes.append(contentsOf: s.utf8) }
}
