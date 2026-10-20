import ByteKit

public struct MP4Box: Equatable, Sendable {
    public let type: String
    public let start: Int
    public let payload: Range<Int>

    public init(type: String, start: Int, payload: Range<Int>) {
        self.type = type
        self.start = start
        self.payload = payload
    }
}

public enum MP4Error: Error, Equatable, Sendable {
    case truncated
    case missing(String)
    case segmentSizeMismatch(expected: Int, actual: Int)
    case unsupported(String)
}

public enum MP4 {
    /// Where children start inside a box's payload (full boxes / sample entries).
    private static let childOffset: [String: Int] = ["stsd": 8, "fLaC": 28]

    public static func children(of bytes: [UInt8], in range: Range<Int>) throws -> [MP4Box] {
        var boxes: [MP4Box] = []
        var o = range.lowerBound
        while o + 8 <= range.upperBound {
            var r = ByteReader(bytes)
            try r.seek(to: o)
            var size = Int(try r.u32BE())
            let type = try r.ascii(4)
            var header = 8
            if size == 1 {
                size = Int(try r.u64BE())
                header = 16
            } else if size == 0 {
                size = range.upperBound - o
            }
            guard size >= header, o + size <= range.upperBound else { throw MP4Error.truncated }
            boxes.append(MP4Box(type: type, start: o, payload: (o + header)..<(o + size)))
            o += size
        }
        return boxes
    }

    public static func find(_ path: [String], in bytes: [UInt8]) throws -> MP4Box? {
        var range = 0..<bytes.count
        for (depth, type) in path.enumerated() {
            guard let box = try children(of: bytes, in: range).first(where: { $0.type == type }) else { return nil }
            if depth == path.count - 1 { return box }
            range = (box.payload.lowerBound + (childOffset[type] ?? 0))..<box.payload.upperBound
        }
        return nil
    }
}
