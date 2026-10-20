public import Foundation

public enum ByteError: Error, Equatable, Sendable {
    case outOfBounds(offset: Int, needed: Int)
    case invalid(String)
}

/// Forward-only cursor over an immutable byte buffer. Value type; copying is cheap (CoW array).
public struct ByteReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public init(_ data: Data) { self.bytes = [UInt8](data) }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { remaining == 0 }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, remaining >= count else { throw ByteError.outOfBounds(offset: offset, needed: count) }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    public func peek() throws -> UInt8 {
        guard remaining >= 1 else { throw ByteError.outOfBounds(offset: offset, needed: 1) }
        return bytes[offset]
    }

    public mutating func u8() throws -> UInt8 { try take(1).first! }
    public mutating func u16BE() throws -> UInt16 { try take(2).reduce(0) { $0 << 8 | UInt16($1) } }
    public mutating func u24BE() throws -> UInt32 { try take(3).reduce(0) { $0 << 8 | UInt32($1) } }
    public mutating func u32BE() throws -> UInt32 { try take(4).reduce(0) { $0 << 8 | UInt32($1) } }
    public mutating func u64BE() throws -> UInt64 { try take(8).reduce(0) { $0 << 8 | UInt64($1) } }
    public mutating func u16LE() throws -> UInt16 { try take(2).reversed().reduce(0) { $0 << 8 | UInt16($1) } }
    public mutating func u32LE() throws -> UInt32 { try take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) } }

    /// ID3v2 "syncsafe" integer: 4 bytes, 7 significant bits each.
    public mutating func syncsafe32() throws -> UInt32 { try take(4).reduce(0) { $0 << 7 | UInt32($1 & 0x7F) } }

    public mutating func bytes(_ count: Int) throws -> [UInt8] { Array(try take(count)) }

    public mutating func ascii(_ count: Int) throws -> String {
        String(decoding: try take(count), as: UTF8.self)
    }

    public mutating func skip(_ count: Int) throws { _ = try take(count) }

    public mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= bytes.count else {
            throw ByteError.outOfBounds(offset: newOffset, needed: 0)
        }
        offset = newOffset
    }
}
