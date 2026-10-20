public struct FrameHeader: Equatable, Sendable {
    public let blockSize: Int
    public let headerLength: Int

    public init(blockSize: Int, headerLength: Int) {
        self.blockSize = blockSize
        self.headerLength = headerLength
    }
}

/// RFC 9639 §9.1 frame header. Returns nil unless sync, field ranges and CRC-8 are all valid.
public enum FrameHeaderParser {
    public static func parse(_ buf: UnsafeRawBufferPointer, at o: Int, maxBlockSize: Int) -> FrameHeader? {
        let n = buf.count
        guard o >= 0, o + 6 <= n, buf[o] == 0xFF, buf[o + 1] & 0xFE == 0xF8 else { return nil }
        let blockCode = buf[o + 2] >> 4
        let rateCode = buf[o + 2] & 0x0F
        let channelCode = buf[o + 3] >> 4
        let sizeCode = (buf[o + 3] >> 1) & 0x07
        guard blockCode != 0, rateCode != 0x0F, channelCode <= 10, sizeCode != 3, buf[o + 3] & 1 == 0 else { return nil }

        var p = o + 4
        let first = buf[p]
        let extra: Int
        switch first {
        case 0x00...0x7F: extra = 0
        case 0xC0...0xDF: extra = 1
        case 0xE0...0xEF: extra = 2
        case 0xF0...0xF7: extra = 3
        case 0xF8...0xFB: extra = 4
        case 0xFC...0xFD: extra = 5
        case 0xFE: extra = 6
        default: return nil
        }
        guard p + 1 + extra <= n else { return nil }
        if extra > 0 {
            for i in 1...extra where buf[p + i] & 0xC0 != 0x80 { return nil }
        }
        p += 1 + extra

        let blockSize: Int
        switch blockCode {
        case 1: blockSize = 192
        case 2...5: blockSize = 576 << Int(blockCode - 2)
        case 6:
            guard p + 1 <= n else { return nil }
            blockSize = Int(buf[p]) + 1
            p += 1
        case 7:
            guard p + 2 <= n else { return nil }
            blockSize = (Int(buf[p]) << 8 | Int(buf[p + 1])) + 1
            p += 2
        default: blockSize = 256 << Int(blockCode - 8)
        }

        switch rateCode {
        case 12: p += 1
        case 13, 14: p += 2
        default: break
        }
        guard p < n else { return nil }
        guard CRC.crc8(UnsafeRawBufferPointer(rebasing: buf[o..<p])) == buf[p] else { return nil }
        if maxBlockSize > 0, blockSize > maxBlockSize { return nil }
        return FrameHeader(blockSize: blockSize, headerLength: p + 1 - o)
    }
}
