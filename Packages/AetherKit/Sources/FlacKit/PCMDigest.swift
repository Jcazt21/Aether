import AudioToolbox
import CryptoKit
public import Foundation

public struct PCMDigestResult: Equatable, Sendable {
    public var md5: [UInt8]
    public var frames: UInt64
}

public enum PCMDigestError: Error, Equatable, Sendable {
    case unsupportedBitDepth(Int)
    case audioToolbox(Int32)
}

/// MD5 over decoded PCM in FLAC's canonical layout (RFC 9639 §8.2): interleaved, signed, little-endian,
/// ceil(bps/8) bytes per sample. Decodes in 64 Ki-frame chunks: constant memory regardless of file size.
public enum PCMDigest {
    public static func md5(ofFileAt url: URL, bitsPerSample: Int, channels: Int, totalFrames: UInt64? = nil,
                           progress: ((Double) -> Void)? = nil) throws -> PCMDigestResult {
        guard [8, 16, 24, 32].contains(bitsPerSample) else { throw PCMDigestError.unsupportedBitDepth(bitsPerSample) }
        var ref: ExtAudioFileRef?
        try check(ExtAudioFileOpenURL(url as CFURL, &ref))
        guard let file = ref else { throw PCMDigestError.audioToolbox(-1) }
        defer { ExtAudioFileDispose(file) }

        var fileFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat))

        let bytesPerSample = bitsPerSample / 8
        let frameBytes = bytesPerSample * channels
        var client = AudioStreamBasicDescription(
            mSampleRate: fileFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(frameBytes), mFramesPerPacket: 1, mBytesPerFrame: UInt32(frameBytes),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: UInt32(bitsPerSample), mReserved: 0)
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))

        let chunkFrames = 65_536
        var buffer = [UInt8](repeating: 0, count: chunkFrames * frameBytes)
        var hasher = Insecure.MD5()
        var decoded: UInt64 = 0
        var lastReported = -1.0
        while true {
            var frames = UInt32(chunkFrames)
            try buffer.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                try check(ExtAudioFileRead(file, &frames, &list))
            }
            if frames == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<(Int(frames) * frameBytes)])) }
            decoded += UInt64(frames)
            if let total = totalFrames, total > 0, let progress {
                let fraction = min(Double(decoded) / Double(total), 1)
                if fraction - lastReported >= 0.02 { progress(fraction); lastReported = fraction }
            }
        }
        if lastReported < 1 { progress?(1) }
        return PCMDigestResult(md5: Array(hasher.finalize()), frames: decoded)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw PCMDigestError.audioToolbox(status) }
    }
}
