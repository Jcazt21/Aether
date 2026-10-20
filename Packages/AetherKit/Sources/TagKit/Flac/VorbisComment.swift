import ByteKit
import Foundation

public struct VorbisComment: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key.uppercased()
            self.value = value
        }
    }

    public var vendor: String
    public private(set) var fields: [Field]

    public init(vendor: String = "Aether", fields: [Field] = []) {
        self.vendor = vendor
        self.fields = fields
    }

    public init(payload: [UInt8]) throws {
        var r = ByteReader(payload)
        let vendorLength = Int(try r.u32LE())
        vendor = String(decoding: try r.bytes(vendorLength), as: UTF8.self)
        let count = Int(try r.u32LE())
        var parsed: [Field] = []
        parsed.reserveCapacity(min(count, 256))
        for _ in 0..<count {
            let length = Int(try r.u32LE())
            let entry = String(decoding: try r.bytes(length), as: UTF8.self)
            guard let eq = entry.firstIndex(of: "=") else { continue }
            parsed.append(Field(key: String(entry[..<eq]), value: String(entry[entry.index(after: eq)...])))
        }
        fields = parsed
    }

    public var payload: [UInt8] {
        var w = ByteWriter()
        let vendorBytes = Array(vendor.utf8)
        w.u32LE(UInt32(vendorBytes.count))
        w.append(vendorBytes)
        w.u32LE(UInt32(fields.count))
        for field in fields {
            let entry = Array("\(field.key)=\(field.value)".utf8)
            w.u32LE(UInt32(entry.count))
            w.append(entry)
        }
        return w.bytes
    }

    public func values(_ key: String) -> [String] {
        let k = key.uppercased()
        return fields.filter { $0.key == k }.map(\.value)
    }

    public func first(_ key: String) -> String? { values(key).first }

    /// Replaces every value of `key`, keeping the position of its first occurrence. Empty values are dropped.
    public mutating func set(_ key: String, _ values: [String]) {
        let k = key.uppercased()
        let position = fields.firstIndex { $0.key == k }
        fields.removeAll { $0.key == k }
        let new = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { Field(key: k, value: $0) }
        fields.insert(contentsOf: new, at: min(position ?? fields.count, fields.count))
    }

    public mutating func set(_ key: String, _ value: String?) {
        set(key, value.map { [$0] } ?? [])
    }
}
