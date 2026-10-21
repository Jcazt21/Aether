public import Foundation
import TagKit

public struct IntegrityReport: Equatable, Sendable, Codable {
    public enum Verdict: String, Codable, Sendable {
        /// Every frame CRC valid, sample counts agree, decoded PCM MD5 == source MD5.
        case verified
        /// Structurally valid, but the file carries no reference MD5 to compare against.
        case verifiedNoReference
        case failed
    }

    public var verdict: Verdict
    public var frames: Int
    public var samples: UInt64
    public var expectedSamples: UInt64?
    public var md5Expected: String?
    public var md5Actual: String?
    public var failure: String?

    public init(verdict: Verdict, frames: Int, samples: UInt64, expectedSamples: UInt64?,
                md5Expected: String?, md5Actual: String?, failure: String?) {
        self.verdict = verdict
        self.frames = frames
        self.samples = samples
        self.expectedSamples = expectedSamples
        self.md5Expected = md5Expected
        self.md5Actual = md5Actual
        self.failure = failure
    }

    public var isPass: Bool { verdict != .failed }
    public var shortMD5: String {
        guard let md5 = md5Actual, md5.count >= 8 else { return "—" }
        return "\(md5.prefix(4))…\(md5.suffix(4))"
    }
}

public enum IntegrityVerifier {
    public static let verifiedFieldKey = "AETHER_VERIFIED"

    /// Cheap checks first (frame CRCs ≈ 10 % of the time, sample counts), PCM MD5 decode last (≈ 90 %).
    public static func verify(flacAt url: URL, expectedSamples: UInt64? = nil,
                              progress: ((Double) -> Void)? = nil) throws -> IntegrityReport {
        let streamInfo = try FlacMetadataIO.read(url).streamInfo()
        let scan = try FlacFrameScanner.scan(fileAt: url) { progress?($0 * 0.1) }
        var report = IntegrityReport(
            verdict: .failed, frames: scan.frames, samples: scan.samples, expectedSamples: expectedSamples,
            md5Expected: streamInfo.hasMD5 ? streamInfo.md5Hex : nil, md5Actual: nil, failure: nil)

        if let bad = scan.firstBadOffset {
            report.failure = "Invalid frame at byte \(bad)"
            return report
        }
        if streamInfo.totalSamples != 0, scan.samples != streamInfo.totalSamples {
            report.failure = "Samples: \(scan.samples) ≠ STREAMINFO \(streamInfo.totalSamples)"
            return report
        }
        if let expected = expectedSamples, scan.samples != expected {
            report.failure = "Samples: \(scan.samples) ≠ expected \(expected)"
            return report
        }

        let digest = try PCMDigest.md5(ofFileAt: url, bitsPerSample: Int(streamInfo.bitsPerSample),
                                       channels: Int(streamInfo.channels), totalFrames: scan.samples) {
            progress?(0.1 + $0 * 0.9)
        }
        report.md5Actual = digest.md5.map { String(format: "%02x", $0) }.joined()
        if digest.frames != scan.samples {
            report.failure = "Decoded \(digest.frames) ≠ \(scan.samples) samples"
            return report
        }
        if streamInfo.hasMD5 {
            report.verdict = digest.md5 == streamInfo.md5 ? .verified : .failed
            if report.verdict == .failed { report.failure = "MD5 does not match the source" }
        } else {
            report.verdict = .verifiedNoReference
        }
        return report
    }

    /// Value stored in the `AETHER_VERIFIED` Vorbis field: `md5:<hex>;<ISO-8601 UTC>`.
    public static func verifiedFieldValue(_ report: IntegrityReport, at date: Date) -> String {
        let formatter = ISO8601DateFormatter()   // not Sendable: created per call, never shared
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .gmt
        return "md5:\(report.md5Actual ?? "");\(formatter.string(from: date))"
    }
}
