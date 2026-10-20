public enum FlacBlockType {
    public static let streamInfo: UInt8 = 0
    public static let padding: UInt8 = 1
    public static let application: UInt8 = 2
    public static let seekTable: UInt8 = 3
    public static let vorbisComment: UInt8 = 4
    public static let cueSheet: UInt8 = 5
    public static let picture: UInt8 = 6
}

public struct FlacBlock: Equatable, Sendable {
    public var type: UInt8
    public var payload: [UInt8]

    public init(type: UInt8, payload: [UInt8]) {
        self.type = type
        self.payload = payload
    }

    public static func padding(_ count: Int) -> FlacBlock {
        FlacBlock(type: FlacBlockType.padding, payload: [UInt8](repeating: 0, count: count))
    }
}

public enum FlacError: Error, Equatable, Sendable {
    case notFlac
    case missingStreamInfo
    case blockTooLarge
}
