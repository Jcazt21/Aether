import Testing
@testable import ByteKit

@Suite struct ByteReaderTests {
    @Test func readsBigAndLittleEndianIntegers() throws {
        var r = ByteReader([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C])
        #expect(try r.u16BE() == 0x0102)
        #expect(try r.u24BE() == 0x030405)
        #expect(try r.u32LE() == 0x0908_0706)
        #expect(r.remaining == 3)
        #expect(try r.peek() == 0x0A)
        #expect(try r.u8() == 0x0A)
    }

    @Test func readsU64AndSyncsafe() throws {
        var r = ByteReader([0, 0, 0, 0, 0, 0, 1, 0, 0x00, 0x00, 0x02, 0x01])
        #expect(try r.u64BE() == 256)
        #expect(try r.syncsafe32() == 257)
    }

    @Test func throwsOutOfBounds() {
        var r = ByteReader([0x01])
        #expect(throws: ByteError.outOfBounds(offset: 0, needed: 2)) { try r.u16BE() }
    }

    @Test func asciiAndSeek() throws {
        var r = ByteReader(Array("fLaCxyz".utf8))
        #expect(try r.ascii(4) == "fLaC")
        try r.seek(to: 1)
        #expect(try r.ascii(3) == "LaC")
        #expect(throws: ByteError.self) { try r.seek(to: 99) }
    }

    @Test func writerRoundTrip() throws {
        var w = ByteWriter()
        w.u8(0xAB); w.u16BE(0x0102); w.u24BE(0x030405); w.u32BE(0x0607_0809)
        w.u64BE(0x0A0B_0C0D_0E0F_1011); w.u32LE(0x1213_1415); w.u16LE(0x1617)
        w.syncsafe32(0x0FFF_FFFF); w.ascii("ID3")
        var r = ByteReader(w.bytes)
        #expect(try r.u8() == 0xAB)
        #expect(try r.u16BE() == 0x0102)
        #expect(try r.u24BE() == 0x030405)
        #expect(try r.u32BE() == 0x0607_0809)
        #expect(try r.u64BE() == 0x0A0B_0C0D_0E0F_1011)
        #expect(try r.u32LE() == 0x1213_1415)
        #expect(try r.u16LE() == 0x1617)
        #expect(try r.syncsafe32() == 0x0FFF_FFFF)
        #expect(try r.ascii(3) == "ID3")
        #expect(r.isAtEnd)
    }
}
