import FlacKit
import Foundation
import Harvester
import HiFiClient
import Observation

/// One observable per queue row: a progress tick invalidates only its own row.
@MainActor
@Observable
final class JobModel: Identifiable {
    let id: UUID
    let request: HarvestRequest
    var phase: HarvestPhase = .queued

    init(request: HarvestRequest) {
        id = request.id
        self.request = request
    }

    var title: String { request.track.displayTitle }

    var subtitle: String {
        [request.track.allArtistNames, request.track.album?.title].compactMap { $0 }.joined(separator: " · ")
    }

    var status: StatusGlyph.Status {
        switch phase {
        case .queued: .queued
        case .resolving, .downloading: .working
        case .verifying: .verifying
        case .verified: .verified
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    var stage: HairlineProgress.Stage {
        switch phase {
        case .queued, .resolving, .cancelled: .idle
        case .downloading: .transferring
        case .verifying: .verifying
        case .verified: .verified
        case .failed: .failed
        }
    }

    var transferFraction: Double {
        switch phase {
        case .downloading(let segment, let total, _, _): total > 0 ? Double(segment) / Double(total) : 0
        case .verifying, .verified: 1
        default: 0
        }
    }

    var verifyFraction: Double {
        switch phase {
        case .verifying(let f): f
        case .verified: 1
        default: 0
        }
    }

    var readout: String {
        switch phase {
        case .queued: "EN COLA"
        case .resolving: "RESOLVIENDO"
        case .downloading(let segment, let total, let bytes, let rate):
            "\(bytes.formatted(.byteCount(style: .file))) · \(String(format: "%.1f", rate / 1_000_000)) MB/s · \(segment)/\(total)"
        case .verifying(let f): "VERIFICANDO · MD5 \(Int(f * 100)) %"
        case .verified(let result): "\(result.format.label) · VERIFICADO \(result.report.shortMD5)"
        case .failed(let message): message
        case .cancelled: "CANCELADO"
        }
    }

    var readoutTone: Readout.Tone {
        switch phase {
        case .verified: .signal
        case .failed: .fault
        case .queued, .cancelled: .tertiary
        default: .secondary
        }
    }
}
