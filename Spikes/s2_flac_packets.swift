// S2: decode raw FLAC frames from a DASH media segment with AVAudioConverter.
// Usage: swift Spikes/s2_flac_packets.swift Spikes/out
import AVFoundation

let dir = URL(filePath: CommandLine.arguments[1])
let initBytes = [UInt8](try Data(contentsOf: dir.appending(path: "init.mp4")))
let segBytes = [UInt8](try Data(contentsOf: dir.appending(path: "seg1.m4s")))

func u32(_ d: [UInt8], _ o: Int) -> Int {
    Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3])
}

func find(_ d: [UInt8], _ path: [String], _ start: Int = 0, _ end: Int? = nil) -> (Int, Int)? {
    var o = start
    let e = end ?? d.count
    while o + 8 <= e {
        let size = u32(d, o)
        let type = String(decoding: d[(o + 4)..<(o + 8)], as: UTF8.self)
        if type == path[0] {
            if path.count == 1 { return (o, size) }
            let skip = ["stsd": 16, "fLaC": 36][type] ?? 8
            return find(d, Array(path.dropFirst()), o + skip, o + size)
        }
        o += size
    }
    return nil
}

let (dfo, dfs) = find(initBytes, ["moov", "trak", "mdia", "minf", "stbl", "stsd", "fLaC", "dfLa"])!
let blocks = Array(initBytes[(dfo + 12)..<(dfo + dfs)])
let streamInfo = Array(blocks[4..<38])
let packed = streamInfo[10..<18].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
let rate = Double(packed >> 44)
let channels = UInt32((packed >> 41) & 7) + 1
let bps = UInt32((packed >> 36) & 31) + 1

let (to, _) = find(segBytes, ["moof", "traf", "trun"])!
let flags = u32(segBytes, to + 8) & 0xFFFFFF
let count = u32(segBytes, to + 12)
var p = to + 16
if flags & 0x1 != 0 { p += 4 }
if flags & 0x4 != 0 { p += 4 }
var sizes: [Int] = []
for _ in 0..<count {
    if flags & 0x100 != 0 { p += 4 }
    sizes.append(u32(segBytes, p)); p += 4
    if flags & 0x400 != 0 { p += 4 }
    if flags & 0x800 != 0 { p += 4 }
}
let (mo, ms) = find(segBytes, ["mdat"])!
let payload = Array(segBytes[(mo + 8)..<(mo + ms)])
precondition(sizes.reduce(0, +) == payload.count, "trun sizes != mdat payload")

let candidates: [(String, [UInt8])] = [
    ("dfLa full box", Array(initBytes[dfo..<(dfo + dfs)])),
    ("dfLa payload (fullbox+blocks)", Array(initBytes[(dfo + 8)..<(dfo + dfs)])),
    ("fLaC + blocks", Array("fLaC".utf8) + blocks),
    ("blocks only", blocks),
]

for (name, cookie) in candidates {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatFLAC,
        mFormatFlags: bps == 16 ? 1 : (bps == 24 ? 3 : 4),
        mBytesPerPacket: 0, mFramesPerPacket: 4096, mBytesPerFrame: 0,
        mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
    guard let inFormat = AVAudioFormat(streamDescription: &asbd) else { print(name, "→ no input format"); continue }
    inFormat.magicCookie = Data(cookie)
    let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { print(name, "→ no converter"); continue }
    let compressed = AVAudioCompressedBuffer(format: inFormat, packetCapacity: AVAudioPacketCount(sizes.count), maximumPacketSize: sizes.max()!)
    payload.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: payload.count) }
    var offset = 0
    for (i, size) in sizes.enumerated() {
        compressed.packetDescriptions![i] = AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
        offset += size
    }
    compressed.packetCount = AVAudioPacketCount(sizes.count)
    compressed.byteLength = UInt32(payload.count)
    let pcm = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(sizes.count * 4096))!
    var delivered = false
    var error: NSError?
    let status = converter.convert(to: pcm, error: &error) { _, outStatus in
        if delivered { outStatus.pointee = .endOfStream; return nil }
        delivered = true
        outStatus.pointee = .haveData
        return compressed
    }
    print("\(name) → status=\(status.rawValue) frames=\(pcm.frameLength) expected=\(sizes.count * 4096) error=\(String(describing: error))")
}
