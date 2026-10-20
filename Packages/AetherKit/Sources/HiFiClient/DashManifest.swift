public import Foundation

public enum DashError: Error, Equatable, Sendable { case missing(String) }

public struct DashManifest: Equatable, Sendable {
    public var representationID: String
    public var codecs: String
    public var sampleRate: Int
    public var channels: Int?
    public var bandwidth: Int?
    public var timescale: Int
    public var initializationURL: URL
    public var mediaTemplate: String
    public var startNumber: Int
    public var segmentDurations: [Int]
    public var presentationDuration: Double?

    public var segmentCount: Int { segmentDurations.count }
    public var segmentNumbers: Range<Int> { startNumber..<(startNumber + segmentCount) }

    /// PCM frames in the stream (timeline units rescaled to the sample rate).
    public var totalSamples: UInt64 {
        let units = segmentDurations.reduce(UInt64(0)) { $0 + UInt64($1) }
        return timescale == sampleRate ? units : units * UInt64(sampleRate) / UInt64(timescale)
    }

    /// "FLAC_HIRES,44100,24" → 24.
    public var bitDepth: Int? { representationID.split(separator: ",").last.flatMap { Int($0) } }

    public var estimatedBytes: Int64? {
        guard let bandwidth, let presentationDuration else { return nil }
        return Int64(Double(bandwidth) * presentationDuration / 8)
    }

    public func mediaURL(number: Int) -> URL {
        URL(string: mediaTemplate
            .replacingOccurrences(of: "$Number$", with: String(number))
            .replacingOccurrences(of: "$RepresentationID$", with: representationID))!
    }

    public static func parse(_ xml: Data) throws -> DashManifest {
        let delegate = MPDParserDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        guard let rep = delegate.representation else { throw DashError.missing("Representation") }
        guard let template = delegate.template else { throw DashError.missing("SegmentTemplate") }
        guard let initString = template["initialization"], let initURL = URL(string: initString) else {
            throw DashError.missing("initialization")
        }
        guard let media = template["media"] else { throw DashError.missing("media") }
        guard let rate = rep["audioSamplingRate"].flatMap(Int.init) else { throw DashError.missing("audioSamplingRate") }
        return DashManifest(
            representationID: rep["id"] ?? "",
            codecs: rep["codecs"] ?? "",
            sampleRate: rate,
            channels: delegate.channels,
            bandwidth: rep["bandwidth"].flatMap(Int.init),
            timescale: template["timescale"].flatMap(Int.init) ?? rate,
            initializationURL: initURL,
            mediaTemplate: media,
            startNumber: template["startNumber"].flatMap(Int.init) ?? 1,
            segmentDurations: delegate.durations,
            presentationDuration: delegate.presentationDuration)
    }
}

extension PlaybackInfo {
    public func dashManifest() throws -> DashManifest {
        guard manifestMimeType == "application/dash+xml", let data = Data(base64Encoded: manifest) else {
            throw HiFiError.unsupportedManifest(manifestMimeType)
        }
        return try DashManifest.parse(data)
    }
}

/// Collects the first audio Representation of the first Period. XML entities (&amp;) are decoded by XMLParser.
private final class MPDParserDelegate: NSObject, XMLParserDelegate {
    var representation: [String: String]?
    var template: [String: String]?
    var channels: Int?
    var durations: [Int] = []
    var presentationDuration: Double?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "MPD":
            presentationDuration = attributes["mediaPresentationDuration"].flatMap(Self.seconds(fromISO8601:))
        case "Representation" where representation == nil:
            representation = attributes
        case "AudioChannelConfiguration" where channels == nil:
            channels = attributes["value"].flatMap(Int.init)
        case "SegmentTemplate" where template == nil:
            template = attributes
        case "S":
            guard let d = attributes["d"].flatMap(Int.init) else { return }
            let repeats = attributes["r"].flatMap(Int.init) ?? 0
            durations.append(contentsOf: repeatElement(d, count: max(repeats, 0) + 1))
        default:
            break
        }
    }

    /// "PT3M56.249S" → 236.249
    static func seconds(fromISO8601 value: String) -> Double? {
        guard value.hasPrefix("PT") else { return nil }
        var total = 0.0
        var number = ""
        for ch in value.dropFirst(2) {
            switch ch {
            case "H": total += (Double(number) ?? 0) * 3600; number = ""
            case "M": total += (Double(number) ?? 0) * 60; number = ""
            case "S": total += Double(number) ?? 0; number = ""
            default: number.append(ch)
            }
        }
        return (total * 1000).rounded() / 1000
    }
}
