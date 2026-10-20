public import TagKit

public enum MP4Fixture {
    public static func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    public static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(8 + payload.count) + Array(type.utf8) + payload }

    public static func initSegment(streamInfo: StreamInfo) -> [UInt8] {
        let dfLa = box("dfLa", [0, 0, 0, 0] + [0x80, 0, 0, 34] + streamInfo.payload)
        let sampleEntry = box("fLaC", [UInt8](repeating: 0, count: 28) + dfLa)
        let stsd = box("stsd", [0, 0, 0, 0, 0, 0, 0, 1] + sampleEntry)
        let moov = box("moov", box("mvhd", [UInt8](repeating: 0, count: 100))
            + box("trak", box("tkhd", [UInt8](repeating: 0, count: 84))
                + box("mdia", box("mdhd", [UInt8](repeating: 0, count: 24))
                    + box("minf", box("stbl", stsd)))))
        return box("ftyp", Array("iso6".utf8) + [0, 0, 0, 0]) + moov
    }

    /// tfhd flags 0x2002A (default duration) + trun flags 0x201 (data offset + sizes), like Tidal.
    public static func mediaSegment(frames: [[UInt8]], duration: UInt32 = 4096, sizeOverride: Int? = nil) -> [UInt8] {
        let tfhd = box("tfhd", [0x00, 0x02, 0x00, 0x2A] + be32(1) + be32(1) + be32(Int(duration)) + be32(0))
        var trun = [0x00, 0x00, 0x02, 0x01] + be32(frames.count) + be32(0)
        for (i, f) in frames.enumerated() { trun += be32(i == 0 ? (sizeOverride ?? f.count) : f.count) }
        let moof = box("moof", box("mfhd", [0, 0, 0, 0] + be32(1)) + box("traf", tfhd + box("tfdt", [UInt8](repeating: 0, count: 12)) + box("trun", trun)))
        return box("styp", Array("msdh".utf8)) + moof + box("mdat", frames.flatMap { $0 })
    }
}
