import ByteKit
import Foundation

public struct StreamInfo: Equatable, Sendable, Codable {
    public var minBlockSize: UInt16
    public var maxBlockSize: UInt16
    public var minFrameSize: UInt32
    public var maxFrameSize: UInt32
    public var sampleRate: UInt32
    public var channels: UInt8
    public var bitsPerSample: UInt8
    public var totalSamples: UInt64
    public var md5: [UInt8]

    public init(minBlockSize: UInt16, maxBlockSize: UInt16, minFrameSize: UInt32, maxFrameSize: UInt32,
                sampleRate: UInt32, channels: UInt8, bitsPerSample: UInt8, totalSamples: UInt64, md5: [UInt8]) {
        self.minBlockSize = minBlockSize
        self.maxBlockSize = maxBlockSize
        self.minFrameSize = minFrameSize
        self.maxFrameSize = maxFrameSize
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.totalSamples = totalSamples
        self.md5 = md5
    }

    public init(payload: [UInt8]) throws {
        guard payload.count == 34 else { throw ByteError.invalid("STREAMINFO length \(payload.count)") }
        var r = ByteReader(payload)
        minBlockSize = try r.u16BE()
        maxBlockSize = try r.u16BE()
        minFrameSize = try r.u24BE()
        maxFrameSize = try r.u24BE()
        let packed = try r.u64BE()
        sampleRate = UInt32(packed >> 44)
        channels = UInt8((packed >> 41) & 0x7) + 1
        bitsPerSample = UInt8((packed >> 36) & 0x1F) + 1
        totalSamples = packed & 0xF_FFFF_FFFF
        md5 = try r.bytes(16)
    }

    public var payload: [UInt8] {
        var w = ByteWriter(reservingCapacity: 34)
        w.u16BE(minBlockSize)
        w.u16BE(maxBlockSize)
        w.u24BE(minFrameSize)
        w.u24BE(maxFrameSize)
        let packed = UInt64(sampleRate) << 44
            | UInt64(channels - 1) << 41
            | UInt64(bitsPerSample - 1) << 36
            | (totalSamples & 0xF_FFFF_FFFF)
        w.u64BE(packed)
        w.append(md5.count == 16 ? md5 : [UInt8](repeating: 0, count: 16))
        return w.bytes
    }

    public var block: FlacBlock { FlacBlock(type: FlacBlockType.streamInfo, payload: payload) }
    public var hasMD5: Bool { md5.contains { $0 != 0 } }
    public var md5Hex: String { md5.map { String(format: "%02x", $0) }.joined() }
    public var duration: Double { sampleRate == 0 ? 0 : Double(totalSamples) / Double(sampleRate) }
}
