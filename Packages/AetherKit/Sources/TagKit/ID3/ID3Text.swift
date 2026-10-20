import Foundation

/// ID3v2 text encodings: 0 ISO-8859-1, 1 UTF-16 with BOM, 2 UTF-16BE, 3 UTF-8.
enum ID3Text {
    static func decode(_ content: [UInt8]) -> [String] {
        guard let encoding = content.first else { return [] }
        var rest = content.dropFirst()
        var values: [String] = []
        while !rest.isEmpty {
            let (head, tail) = splitTerminated(rest, encoding: encoding)
            if let s = decodeString(head, encoding: encoding), !s.isEmpty { values.append(s) }
            rest = tail
        }
        return values
    }

    /// Encodes for ID3v2.3 compatibility: Latin-1 when possible, otherwise UTF-16 LE with BOM.
    static func encode(_ s: String) -> [UInt8] {
        if s.unicodeScalars.allSatisfy({ $0.value < 0x100 }) {
            return [0] + s.unicodeScalars.map { UInt8($0.value) }
        }
        return [1, 0xFF, 0xFE] + s.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }
    }

    static func terminator(for encoding: UInt8) -> [UInt8] { encoding == 1 || encoding == 2 ? [0, 0] : [0] }

    /// Splits at the first terminator; `rest` is empty when none is found.
    static func splitTerminated(_ bytes: ArraySlice<UInt8>, encoding: UInt8) -> (head: [UInt8], rest: ArraySlice<UInt8>) {
        var i = bytes.startIndex
        if encoding == 1 || encoding == 2 {
            while i + 1 < bytes.endIndex {
                if bytes[i] == 0, bytes[i + 1] == 0 { return (Array(bytes[bytes.startIndex..<i]), bytes[(i + 2)...]) }
                i += 2
            }
        } else if let z = bytes.firstIndex(of: 0) {
            return (Array(bytes[bytes.startIndex..<z]), bytes[(z + 1)...])
        }
        return (Array(bytes), [])
    }

    static func decodeString(_ bytes: [UInt8], encoding: UInt8) -> String? {
        switch encoding {
        case 0: return String(bytes: bytes, encoding: .isoLatin1)
        case 1:
            if bytes.starts(with: [0xFE, 0xFF]) { return String(bytes: bytes.dropFirst(2), encoding: .utf16BigEndian) }
            if bytes.starts(with: [0xFF, 0xFE]) { return String(bytes: bytes.dropFirst(2), encoding: .utf16LittleEndian) }
            return String(bytes: bytes, encoding: .utf16LittleEndian)
        case 2: return String(bytes: bytes, encoding: .utf16BigEndian)
        case 3: return String(bytes: bytes, encoding: .utf8)
        default: return nil
        }
    }
}

/// Reverses ID3 unsynchronisation: every `FF 00` becomes `FF`.
func removeUnsynchronisation(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        out.append(bytes[i])
        if bytes[i] == 0xFF, i + 1 < bytes.count, bytes[i + 1] == 0x00 { i += 2 } else { i += 1 }
    }
    return out
}
