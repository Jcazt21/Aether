import Testing
@testable import FlacKit

@Suite struct CRCAndHeaderTests {
    @Test func crcCheckValues() {
        let check = Array("123456789".utf8)
        #expect(CRC.crc8(check) == 0xF4)     // CRC-8 (poly 0x07)
        #expect(CRC.crc16(check) == 0xFEE8)  // CRC-16/BUYPASS (poly 0x8005)
    }

    /// Fixed-blocksize header: sync FFF8, blocksize code 12 (4096), sample-rate code 9 (44.1 kHz),
    /// stereo, 24-bit, frame number 0, then CRC-8.
    private func header(frameNumber: UInt8 = 0) -> [UInt8] {
        let body: [UInt8] = [0xFF, 0xF8, 0xC9, 0x1C, frameNumber]
        return body + [CRC.crc8(body)]
    }

    @Test func parsesValidHeader() {
        let bytes = header() + [0, 0, 0]
        let parsed = bytes.withUnsafeBytes { FrameHeaderParser.parse($0, at: 0, maxBlockSize: 4096) }
        #expect(parsed == FrameHeader(blockSize: 4096, headerLength: 6))
    }

    @Test func rejectsBadCRCReservedBitsAndOversizedBlocks() {
        var bad = header()
        bad[5] ^= 0xFF
        #expect(bad.withUnsafeBytes { FrameHeaderParser.parse($0, at: 0, maxBlockSize: 4096) } == nil)

        let reservedBody: [UInt8] = [0xFF, 0xF8, 0xC9, 0x1D, 0x00]
        let reserved = reservedBody + [CRC.crc8(reservedBody)]
        #expect(reserved.withUnsafeBytes { FrameHeaderParser.parse($0, at: 0, maxBlockSize: 4096) } == nil)

        #expect(header().withUnsafeBytes { FrameHeaderParser.parse($0, at: 0, maxBlockSize: 1152) } == nil)
    }

    @Test func parsesExplicitBlockSizeAndMultiByteFrameNumber() {
        // blocksize code 7 (16-bit explicit, value-1), sample-rate code 12 (8-bit kHz), frame number 0xC2 0x80 (=128).
        let body: [UInt8] = [0xFF, 0xF8, 0x7C, 0x18, 0xC2, 0x80, 0x0F, 0xFF, 0x30]
        let bytes = body + [CRC.crc8(body)]
        let parsed = bytes.withUnsafeBytes { FrameHeaderParser.parse($0, at: 0, maxBlockSize: 0) }
        #expect(parsed == FrameHeader(blockSize: 4096, headerLength: 10))
    }

    @Test func rejectsTruncatedInput() {
        let bytes: [UInt8] = [0xFF, 0xF8, 0xC9]
        #expect(bytes.withUnsafeBytes { FrameHeaderParser.parse($0, at: 0, maxBlockSize: 0) } == nil)
    }
}
