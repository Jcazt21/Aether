import CryptoKit
import FlacKit
import Foundation
import HiFiClient
import Synchronization
import TagKit
import TestSupport

/// Serves /track, /album, init and media segments built from a real AudioToolbox-encoded FLAC.
final class FakeTidal: Sendable {
    private final class State: Sendable {
        let forbiddenOnce = Mutex<Set<Int>>([])
        let manifestRequests = Counter()
    }

    let base: URL
    let streamInfo: StreamInfo
    let expectedSamples: UInt64
    private let state = State()

    var manifestRequestCount: Int { state.manifestRequests.value }
    var client: HiFiClient { HiFiClient(baseURL: base, imageBaseURL: base.appending(path: "images"), session: StubURLProtocol.session()) }

    init(seconds: Double = 3, bits: Int = 24, sampleRate: Int = 44_100, reportedSampleRate: Int? = nil,
         corruptSegment: Int? = nil, expireSegmentOnce: Int? = nil) throws {
        let (url, pcm) = try AudioFixture.makeFLAC(seconds: seconds, sampleRate: Double(sampleRate), bits: bits)
        var header = try FlacMetadataIO.read(url)
        var si = try header.streamInfo()
        si.md5 = Array(Insecure.MD5.hash(data: pcm))
        header.blocks[0] = si.block
        try FlacMetadataIO.write(header.blocks, to: url)
        streamInfo = si
        expectedSamples = UInt64(pcm.count / (2 * bits / 8))

        let bytes = [UInt8](try Data(contentsOf: url))
        let scan = try FlacFrameScanner.scan(fileAt: url, collectOffsets: true)
        let offsets = scan.frameOffsets! + [bytes.count]
        let frames = (0..<scan.frames).map { Array(bytes[offsets[$0]..<offsets[$0 + 1]]) }
        let block = Int(si.maxBlockSize)
        var segments: [[UInt8]] = []
        var durations: [Int] = []
        let body = Array(frames.dropLast())
        for start in stride(from: 0, to: body.count, by: 43) {
            let chunk = Array(body[start..<min(start + 43, body.count)])
            segments.append(MP4Fixture.mediaSegment(frames: chunk, duration: UInt32(block)))
            durations.append(chunk.count * block)
        }
        let tail = Int(si.totalSamples) - (frames.count - 1) * block
        segments.append(MP4Fixture.mediaSegment(frames: [frames.last!], duration: UInt32(tail)))
        durations.append(tail)
        if let bad = corruptSegment {
            var seg = segments[bad - 1]
            seg[seg.count - 100] ^= 0x01
            segments[bad - 1] = seg
        }
        if let expire = expireSegmentOnce { state.forbiddenOnce.withLock { _ = $0.insert(expire) } }

        let initSegment = MP4Fixture.initSegment(streamInfo: si)
        let timeline = durations.map { #"<S d="\#($0)"/>"# }.joined()
        let state = state
        let rate = reportedSampleRate ?? sampleRate
        let segs = segments
        base = StubURLProtocol.register { request in
            let url = request.url!
            let origin = "http://\(url.host!)"
            switch url.path {
            case "/track", "/track/":
                state.manifestRequests.increment()
                let mpd = """
                <MPD mediaPresentationDuration="PT\(seconds)S"><Period><AdaptationSet mimeType="audio/mp4"><Representation id="FLAC,\(sampleRate),\(bits)" codecs="flac" bandwidth="1000000" audioSamplingRate="\(sampleRate)"><AudioChannelConfiguration value="2"/><SegmentTemplate timescale="\(sampleRate)" initialization="\(origin)/init.mp4" media="\(origin)/seg/$Number$.mp4" startNumber="1"><SegmentTimeline>\(timeline)</SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>
                """
                let json = #"{"version":"2.10","data":{"trackId":1,"audioQuality":"HI_RES_LOSSLESS","manifestMimeType":"application/dash+xml","manifest":"\#(Data(mpd.utf8).base64EncodedString())","bitDepth":\#(bits),"sampleRate":\#(rate),"trackReplayGain":-9.5,"trackPeakAmplitude":0.99}}"#
                return (200, Data(json.utf8))
            case "/album", "/album/":
                return (200, Data(#"{"version":"2.10","data":{"id":9,"title":"Fixture EP","releaseDate":"2026-01-02","copyright":"(C) 2026 Test Records","artists":[{"id":1,"name":"Fixture","type":"MAIN"}],"items":[]}}"#.utf8))
            case "/init.mp4":
                return (200, Data(initSegment))
            case let path where path.hasPrefix("/seg/"):
                let n = Int(url.deletingPathExtension().lastPathComponent)!
                if state.forbiddenOnce.withLock({ $0.remove(n) != nil }) { return (403, Data()) }
                return (200, Data(segs[n - 1]))
            case let path where path.hasPrefix("/images/"):
                return (200, Data([0xFF, 0xD8, 0xFF, 0xD9]))
            default:
                return (404, Data())
            }
        }
    }

    static func track() throws -> TidalTrack {
        try JSONDecoder().decode(TidalTrack.self, from: Data("""
        {"id":1,"title":"Tone","version":"Original Mix","duration":3,"trackNumber":1,"volumeNumber":1,
         "artist":{"id":1,"name":"Fixture","type":"MAIN"},"artists":[{"id":1,"name":"Fixture","type":"MAIN"}],
         "album":{"id":9,"title":"Fixture EP","cover":"aa-bb"}}
        """.utf8))
    }
}
