public import FlacKit
public import Foundation
public import HiFiClient

public enum QualityPolicy: String, Codable, Sendable, CaseIterable {
    case hiResCapped96, hiRes, lossless

    public var initialQuality: AudioQuality { self == .lossless ? .lossless : .hiResLossless }

    public var title: String {
        switch self {
        case .hiResCapped96: "Hi-Res ≤ 96 kHz (CDJ)"
        case .hiRes: "Hi-Res maximum"
        case .lossless: "Always 16 bit / 44.1 kHz"
        }
    }
}

public struct HarvestRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var track: TidalTrack
    public var destinationFolder: URL
    public var genre: String?
    public var policy: QualityPolicy
    public var createdAt: Date
    public var filenameTemplate: String?

    public init(track: TidalTrack, destinationFolder: URL, genre: String?, policy: QualityPolicy,
                filenameTemplate: String? = nil) {
        self.filenameTemplate = filenameTemplate
        id = UUID()
        self.track = track
        self.destinationFolder = destinationFolder
        self.genre = genre
        self.policy = policy
        createdAt = Date()
    }
}

public struct FormatSummary: Codable, Sendable, Equatable {
    public var sampleRate: Int
    public var bitDepth: Int
    public var channels: Int
    public var duration: Double

    public init(sampleRate: Int, bitDepth: Int, channels: Int, duration: Double) {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.duration = duration
    }

    /// "FLAC · 24/96" style, kHz without trailing zeros.
    public var label: String {
        let khz = Double(sampleRate) / 1000
        let rate = khz.rounded() == khz ? String(Int(khz)) : String(format: "%.1f", khz)
        return "FLAC · \(bitDepth)/\(rate)"
    }
}

public struct HarvestResult: Codable, Sendable, Equatable {
    public var fileURL: URL
    public var report: IntegrityReport
    public var format: FormatSummary
    public var bytes: Int64
    public var finishedAt: Date

    public init(fileURL: URL, report: IntegrityReport, format: FormatSummary, bytes: Int64, finishedAt: Date) {
        self.fileURL = fileURL
        self.report = report
        self.format = format
        self.bytes = bytes
        self.finishedAt = finishedAt
    }
}

public enum HarvestPhase: Sendable, Equatable {
    case queued
    case resolving
    case downloading(segment: Int, of: Int, bytes: Int64, bytesPerSecond: Double)
    case verifying(Double)
    case verified(HarvestResult)
    case failed(String)
    case cancelled

    public var isActive: Bool {
        switch self {
        case .resolving, .downloading, .verifying: true
        default: false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .verified, .failed, .cancelled: true
        default: false
        }
    }
}

public struct HarvestEvent: Sendable {
    public var id: UUID
    public var phase: HarvestPhase
}

public enum HarvestError: Error, Equatable, Sendable {
    case http(Int)
    case integrity(String)
    case cancelled
}
