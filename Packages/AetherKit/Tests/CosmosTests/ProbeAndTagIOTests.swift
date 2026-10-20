import AudioToolbox
import Foundation
import Testing
@testable import Cosmos
import TagKit
import TestSupport

@Suite struct ProbeAndTagIOTests {
    typealias AudioFormatInfo = Cosmos.AudioFormatInfo
    @Test func probesFlacFromStreamInfo() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 2, sampleRate: 96_000, bits: 24)
        let info = try AudioProbe.probe(url)
        #expect(info.codec == .flac)
        #expect(info.sampleRate == 96_000)
        #expect(info.bitDepth == 24)
        #expect(abs(info.duration - 2) < 0.01)
        #expect(info.isLossless)
        #expect(info.label == "FLAC 24/96")
    }

    @Test(arguments: [(kAudioFileWAVEType, "wav", AudioFormatInfo.Codec.wav), (kAudioFileAIFFType, "aiff", .aiff)])
    func probesPCMContainers(type: AudioFileTypeID, ext: String, codec: AudioFormatInfo.Codec) throws {
        let url = try AudioFixture.makePCMFile(type: type, ext: ext, seconds: 1)
        let info = try AudioProbe.probe(url)
        #expect(info.codec == codec)
        #expect(info.bitDepth == 16)
        #expect(info.label == "\(codec.rawValue.uppercased()) 16/44.1")
    }

    @Test func codecMapping() {
        #expect(AudioProbe.codec(formatID: kAudioFormatMPEGLayer3, fileExtension: "mp3") == .mp3)
        #expect(AudioProbe.codec(formatID: kAudioFormatMPEG4AAC, fileExtension: "m4a") == .aac)
        #expect(AudioProbe.codec(formatID: kAudioFormatAppleLossless, fileExtension: "m4a") == .alac)
        #expect(AudioFormatInfo(codec: .mp3, sampleRate: 44_100, bitDepth: nil, channels: 2, duration: 1, bitRate: 320).label == "MP3 320")
    }

    @Test func tagIORoundTripsFlacAndReadsVerifiedStamp() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 1)
        try FlacTags.write(TrackTags(title: "Feel", artist: "Franky Rizardo"), to: url,
                           extraFields: ["AETHER_VERIFIED": "md5:abcd;2026-10-20T00:00:00Z"])
        #expect(try TagIO.read(url).title == "Feel")
        #expect(TagIO.verifiedStamp(url) == "md5:abcd;2026-10-20T00:00:00Z")
        try TagIO.write(TrackTags(title: "Feel (Extended)", artist: "Franky Rizardo"), to: url)
        #expect(try TagIO.read(url).title == "Feel (Extended)")
        #expect(TagIO.isWritable(url))
        #expect(!TagIO.isWritable(URL(filePath: "/x.m4a")))
    }

    @Test func itemReaderBuildsSummaryWithoutArtwork() throws {
        let (url, _) = try AudioFixture.makeFLAC(seconds: 1)
        try FlacTags.write(TrackTags(title: "Baby", artist: "Prospa", bpm: 130,
                                     artwork: .init(data: Data([0xFF, 0xD8, 0xFF, 0xD9]), mimeType: "image/jpeg")), to: url)
        let item = try ItemReader.read(url: url, relativePath: "UK House/Prospa - Baby.flac", fileSize: 10, modified: .distantPast)
        #expect(item.folder == "UK House")
        #expect(item.fileName == "Prospa - Baby.flac")
        #expect(item.hasArtwork)
        #expect(item.tags.artwork == nil)
        #expect(item.bpmValue == 130)
        #expect(item.displayArtist == "Prospa")
    }

    @Test func displayFallsBackToFileName() {
        let item = LibraryItem(relativePath: "b2bsept.wav", fileSize: 1, modified: .distantPast,
                               format: AudioFormatInfo(codec: .wav, sampleRate: 44_100, bitDepth: 16, channels: 2, duration: 1, bitRate: nil),
                               tags: TrackTags(), hasArtwork: false, verifiedStamp: nil)
        #expect(item.folder == "")
        #expect(item.displayTitle == "b2bsept")
        let named = LibraryItem(relativePath: "UK House/Kettama - Comes and Goes.flac", fileSize: 1, modified: .distantPast,
                                format: item.format, tags: TrackTags(), hasArtwork: false, verifiedStamp: nil)
        #expect(named.displayArtist == "Kettama")
        #expect(named.displayTitle == "Comes and Goes")
    }
}
