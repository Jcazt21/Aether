import ByteKit

public enum ID3Error: Error, Equatable, Sendable {
    case unsupportedVersion(UInt8)
    case malformed
}

public struct ID3Frame: Equatable, Sendable {
    public var id: String
    public var flags: UInt16
    public var payload: [UInt8]

    public init(id: String, flags: UInt16, payload: [UInt8]) {
        self.id = id
        self.flags = flags
        self.payload = payload
    }

    /// Payload with v2.4 per-frame unsynchronisation and data-length indicator removed.
    public func content(major: UInt8) -> [UInt8] {
        guard major == 4 else { return payload }
        var bytes = payload
        if flags & 0x0001 != 0, bytes.count >= 4 { bytes.removeFirst(4) }
        if flags & 0x0002 != 0 { bytes = removeUnsynchronisation(bytes) }
        return bytes
    }
}

public struct ID3Tag: Equatable, Sendable {
    public var majorVersion: UInt8
    public var frames: [ID3Frame]

    public init(majorVersion: UInt8 = 3, frames: [ID3Frame] = []) {
        self.majorVersion = majorVersion
        self.frames = frames
    }

    /// Total on-disk size (header + body + optional v2.4 footer) declared by a 10-byte header.
    public static func declaredSize(header: [UInt8]) -> Int? {
        guard header.count >= 10, header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 else { return nil }
        let size = header[6..<10].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
        let footer = header[3] == 4 && header[5] & 0x10 != 0 ? 10 : 0
        return 10 + size + footer
    }

    public static func parse(_ bytes: [UInt8]) throws -> ID3Tag {
        guard declaredSize(header: Array(bytes.prefix(10))) != nil else { throw ID3Error.malformed }
        let major = bytes[3]
        guard major == 3 || major == 4 else { throw ID3Error.unsupportedVersion(major) }
        let flags = bytes[5]
        let bodySize = bytes[6..<10].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
        var body = Array(bytes[10..<min(10 + bodySize, bytes.count)])
        if major == 3, flags & 0x80 != 0 { body = removeUnsynchronisation(body) }

        var r = ByteReader(body)
        if flags & 0x40 != 0 {
            if major == 3 { try r.skip(Int(try r.u32BE())) } else { try r.skip(Int(try r.syncsafe32()) - 4) }
        }
        var frames: [ID3Frame] = []
        while r.remaining >= 10, try r.peek() != 0 {
            let id = try r.ascii(4)
            guard id.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }) else { break }
            let size = try Int(major == 4 ? r.syncsafe32() : r.u32BE())
            let frameFlags = try r.u16BE()
            guard size <= r.remaining else { break }
            frames.append(ID3Frame(id: id, flags: frameFlags, payload: try r.bytes(size)))
        }
        return ID3Tag(majorVersion: major, frames: frames)
    }

    /// When the body fits in `minimumSize` the result is exactly that long (in-place rewrite);
    /// otherwise `padding` zero bytes are appended for future edits.
    public func serialize(minimumSize: Int = 0, padding: Int = 2048) -> [UInt8] {
        var body = ByteWriter()
        for frame in frames {
            body.ascii(frame.id)
            if majorVersion == 4 { body.syncsafe32(UInt32(frame.payload.count)) } else { body.u32BE(UInt32(frame.payload.count)) }
            body.u16BE(frame.flags)
            body.append(frame.payload)
        }
        var bodyBytes = body.bytes
        let available = minimumSize - 10
        let fill = available >= bodyBytes.count ? available - bodyBytes.count : padding
        bodyBytes.append(contentsOf: repeatElement(0, count: fill))

        var w = ByteWriter(reservingCapacity: 10 + bodyBytes.count)
        w.ascii("ID3")
        w.u8(majorVersion)
        w.u8(0)
        w.u8(0)
        w.syncsafe32(UInt32(bodyBytes.count))
        w.append(bodyBytes)
        return w.bytes
    }

    public mutating func remove(_ id: String) { frames.removeAll { $0.id == id } }

    public mutating func setText(_ id: String, _ value: String?) {
        let position = frames.firstIndex { $0.id == id }
        remove(id)
        guard let value = value?.nilIfBlank else { return }
        frames.insert(ID3Frame(id: id, flags: 0, payload: ID3Text.encode(value)),
                      at: min(position ?? frames.count, frames.count))
    }

    public func text(_ id: String) -> String? {
        frames.first { $0.id == id }
            .map { ID3Text.decode($0.content(major: majorVersion)).joined(separator: ", ") }?
            .nilIfBlank
    }
}
