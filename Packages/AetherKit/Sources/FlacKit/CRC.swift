public enum CRC {
    private static let table8: [UInt8] = (0..<256).map { i in
        var c = UInt8(i)
        for _ in 0..<8 { c = c & 0x80 != 0 ? (c << 1) ^ 0x07 : c << 1 }
        return c
    }

    private static let table16: [UInt16] = (0..<256).map { i in
        var c = UInt16(i) << 8
        for _ in 0..<8 { c = c & 0x8000 != 0 ? (c << 1) ^ 0x8005 : c << 1 }
        return c
    }

    public static func crc8(_ bytes: UnsafeRawBufferPointer) -> UInt8 {
        table8.withUnsafeBufferPointer { table in
            var crc: UInt8 = 0
            for byte in bytes { crc = table[Int(crc ^ byte)] }
            return crc
        }
    }

    public static func crc16(_ bytes: UnsafeRawBufferPointer) -> UInt16 {
        table16.withUnsafeBufferPointer { table in
            var crc: UInt16 = 0
            for byte in bytes { crc = (crc << 8) ^ table[Int(UInt8(crc >> 8) ^ byte)] }
            return crc
        }
    }

    public static func crc8(_ bytes: [UInt8]) -> UInt8 { bytes.withUnsafeBytes { crc8($0) } }
    public static func crc16(_ bytes: [UInt8]) -> UInt16 { bytes.withUnsafeBytes { crc16($0) } }
}
