import AudioToolbox
public import Foundation
import TagKit

public struct AudioFormatInfo: Codable, Sendable, Equatable {
    public enum Codec: String, Codable, Sendable { case flac, wav, aiff, mp3, aac, alac, other }

    public var codec: Codec
    public var sampleRate: Double
    public var bitDepth: Int?
    public var channels: Int
    public var duration: Double
    public var bitRate: Int?

    public init(codec: Codec, sampleRate: Double, bitDepth: Int?, channels: Int, duration: Double, bitRate: Int?) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.duration = duration
        self.bitRate = bitRate
    }

    public var isLossless: Bool { [.flac, .wav, .aiff, .alac].contains(codec) }

    public var label: String {
        let name = codec.rawValue.uppercased()
        if isLossless, let bitDepth {
            let khz = sampleRate / 1000
            let rate = khz.rounded() == khz ? String(Int(khz)) : String(format: "%.1f", khz)
            return "\(name) \(bitDepth)/\(rate)"
        }
        return bitRate.map { "\(name) \($0)" } ?? name
    }
}

public enum AudioProbe {
    public static func probe(_ url: URL) throws -> AudioFormatInfo {
        if url.pathExtension.lowercased() == "flac" {
            let si = try FlacMetadataIO.read(url).streamInfo()
            return AudioFormatInfo(codec: .flac, sampleRate: Double(si.sampleRate), bitDepth: Int(si.bitsPerSample),
                                   channels: Int(si.channels), duration: si.duration, bitRate: nil)
        }
        var fileID: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID)
        guard status == noErr, let file = fileID else { throw CocoaError(.fileReadCorruptFile) }
        defer { AudioFileClose(file) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd)
        var duration: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration)
        var bitRate: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &bitRate)
        var sourceDepth: Int32 = 0
        size = UInt32(MemoryLayout<Int32>.size)
        AudioFileGetProperty(file, kAudioFilePropertySourceBitDepth, &size, &sourceDepth)

        let codec = codec(formatID: asbd.mFormatID, fileExtension: url.pathExtension.lowercased())
        let depth: Int? = asbd.mFormatID == kAudioFormatLinearPCM ? Int(asbd.mBitsPerChannel)
            : (sourceDepth > 0 ? Int(sourceDepth) : nil)
        return AudioFormatInfo(codec: codec, sampleRate: asbd.mSampleRate, bitDepth: depth,
                               channels: Int(asbd.mChannelsPerFrame), duration: duration,
                               bitRate: bitRate > 0 ? Int((Double(bitRate) / 1000).rounded()) : nil)
    }

    public static func codec(formatID: UInt32, fileExtension: String) -> AudioFormatInfo.Codec {
        switch formatID {
        case kAudioFormatLinearPCM: ["aif", "aiff", "aifc"].contains(fileExtension) ? .aiff : .wav
        case kAudioFormatMPEGLayer3: .mp3
        case kAudioFormatMPEG4AAC: .aac
        case kAudioFormatAppleLossless: .alac
        case kAudioFormatFLAC: .flac
        default: .other
        }
    }
}
