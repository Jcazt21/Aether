@preconcurrency public import AVFAudio
import ByteKit
public import FlacKit
public import Foundation

public enum StreamCookie {
    /// Variant validated by spike S2 (docs/spikes.md). Default: the full `dfLa` box.
    public static func make(from initSegment: [UInt8]) throws -> Data {
        guard let dfLa = try MP4.find(["moov", "trak", "mdia", "minf", "stbl", "stsd", "fLaC", "dfLa"], in: initSegment) else {
            throw MP4Error.missing("dfLa")
        }
        return Data(initSegment[dfLa.start..<dfLa.payload.upperBound])
    }
}

public final class FlacPacketDecoder {
    public let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let maxPacketSize: Int
    private let blockSize: AVAudioFrameCount

    public init(config: FlacTrackConfig, cookie: Data, maxPacketSize: Int) throws {
        let si = config.streamInfo
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(si.sampleRate), mFormatID: kAudioFormatFLAC,
            mFormatFlags: si.bitsPerSample == 16 ? 1 : (si.bitsPerSample == 24 ? 3 : 4),
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(si.maxBlockSize), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(si.channels), mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(standardFormatWithSampleRate: Double(si.sampleRate), channels: AVAudioChannelCount(si.channels))
        else { throw MP4Error.unsupported("FLAC stream format") }
        input.magicCookie = cookie
        guard let converter = AVAudioConverter(from: input, to: output) else { throw MP4Error.unsupported("FLAC decoder") }
        inputFormat = input
        outputFormat = output
        self.converter = converter
        self.maxPacketSize = maxPacketSize
        blockSize = AVAudioFrameCount(si.maxBlockSize)
    }

    public func decode(segment bytes: [UInt8]) throws -> AVAudioPCMBuffer {
        let parsed = try FMP4Flac.parseMediaSegment(bytes)
        let sizes = try packetSizes(bytes)
        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: AVAudioPacketCount(sizes.count),
                                                 maximumPacketSize: max(maxPacketSize, sizes.max() ?? 0))
        var offset = 0
        for range in parsed.frameRanges {
            bytes[range].withUnsafeBytes { compressed.data.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: range.count) }
            offset += range.count
        }
        var start = 0
        for (i, size) in sizes.enumerated() {
            compressed.packetDescriptions![i] = AudioStreamPacketDescription(mStartOffset: Int64(start), mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
            start += size
        }
        compressed.packetCount = AVAudioPacketCount(sizes.count)
        compressed.byteLength = UInt32(offset)

        guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(parsed.samples) + blockSize) else {
            throw MP4Error.unsupported("PCM buffer")
        }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in
            if delivered { outStatus.pointee = .noDataNow; return nil }
            delivered = true
            outStatus.pointee = .haveData
            return compressed
        }
        if status == .error { throw error ?? MP4Error.unsupported("decode") }
        return pcm
    }

    /// Per-sample sizes from `trun` (FMP4Flac validates their sum against mdat).
    private func packetSizes(_ bytes: [UInt8]) throws -> [Int] {
        guard let trun = try MP4.find(["moof", "traf", "trun"], in: bytes) else { throw MP4Error.missing("trun") }
        var r = ByteReader(Array(bytes[trun.payload]))
        let flags = try r.u32BE() & 0xFF_FFFF
        let count = Int(try r.u32BE())
        if flags & 0x001 != 0 { try r.skip(4) }
        if flags & 0x004 != 0 { try r.skip(4) }
        guard flags & 0x200 != 0 else { throw MP4Error.unsupported("trun without sample sizes") }
        var sizes: [Int] = []
        sizes.reserveCapacity(count)
        for _ in 0..<count {
            if flags & 0x100 != 0 { try r.skip(4) }
            sizes.append(Int(try r.u32BE()))
            if flags & 0x400 != 0 { try r.skip(4) }
            if flags & 0x800 != 0 { try r.skip(4) }
        }
        return sizes
    }
}
