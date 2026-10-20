public import AudioToolbox
public import Foundation

public enum AudioFixture {
    public struct Failure: Error { public let status: OSStatus }

    private static func check(_ s: OSStatus) throws { if s != noErr { throw Failure(status: s) } }

    /// Encodes a deterministic two-tone signal to FLAC and returns the exact PCM fed to the encoder
    /// (interleaved, signed, little-endian, `bits/8` bytes per sample) — the FLAC MD5 reference layout.
    public static func makeFLAC(seconds: Double = 2, sampleRate: Double = 44_100, bits: Int = 16, channels: Int = 2) throws -> (url: URL, pcm: [UInt8]) {
        let frames = Int(seconds * sampleRate)
        let bytesPerSample = bits / 8
        let amplitude = Double((1 << (bits - 1)) - 1) * 0.6
        var pcm = [UInt8]()
        pcm.reserveCapacity(frames * channels * bytesPerSample)
        for i in 0..<frames {
            for c in 0..<channels {
                let t = Double(i) / sampleRate
                let v = Int32(amplitude * sin(2 * .pi * (440 + Double(c) * 110) * t))
                for b in 0..<bytesPerSample { pcm.append(UInt8(truncatingIfNeeded: v >> (8 * b))) }
            }
        }

        let url = FileManager.default.temporaryDirectory.appending(path: "fixture-\(UUID().uuidString).flac")
        var flac = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatFLAC, mFormatFlags: bits == 16 ? 1 : 3,
            mBytesPerPacket: 0, mFramesPerPacket: 4096, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var ref: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileFLACType, &flac, nil,
                                            AudioFileFlags.eraseFile.rawValue, &ref))
        guard let file = ref else { throw Failure(status: -1) }
        defer { ExtAudioFileDispose(file) }

        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerSample * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerSample * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(bits), mReserved: 0)
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))

        let frameBytes = bytesPerSample * channels
        var written = 0
        try pcm.withUnsafeMutableBytes { raw in
            while written < frames {
                let count = min(4096, frames - written)
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(count * frameBytes),
                    mData: raw.baseAddress! + written * frameBytes))
                try check(ExtAudioFileWrite(file, UInt32(count), &list))
                written += count
            }
        }
        return (url, pcm)
    }
}
