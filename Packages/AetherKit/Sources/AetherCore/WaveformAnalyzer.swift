import Accelerate
@preconcurrency import AVFAudio
public import Foundation

public enum WaveformAnalyzer {
    /// Decodes in 64 Ki-frame chunks and keeps the absolute peak per bin across all channels.
    /// Blocking: call from a detached task.
    public static func peaks(for url: URL, bins: Int = 1200) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let total = max(file.length, 1)
        let framesPerBin = max(Double(total) / Double(bins), 1)
        var result = [Float](repeating: 0, count: bins)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else { return result }
        var position: Int64 = 0
        while position < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            var offset = 0
            while offset < frames {
                let bin = min(Int(Double(position + Int64(offset)) / framesPerBin), bins - 1)
                let binEnd = Int64((Double(bin + 1) * framesPerBin).rounded(.up))
                let count = min(frames - offset, max(Int(binEnd - (position + Int64(offset))), 1))
                for ch in 0..<Int(buffer.format.channelCount) {
                    var peak: Float = 0
                    vDSP_maxmgv(data[ch] + offset, 1, &peak, vDSP_Length(count))
                    result[bin] = max(result[bin], peak)
                }
                offset += count
            }
            position += Int64(frames)
        }
        return result
    }
}
