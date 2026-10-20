public import Foundation
import ByteKit

public struct FlacPicture: Equatable, Sendable {
    public var pictureType: UInt32
    public var mimeType: String
    public var description: String
    public var width: UInt32
    public var height: UInt32
    public var depth: UInt32
    public var colors: UInt32
    public var data: [UInt8]

    public init(pictureType: UInt32 = 3, mimeType: String, description: String = "",
                width: UInt32 = 0, height: UInt32 = 0, depth: UInt32 = 24, colors: UInt32 = 0, data: [UInt8]) {
        self.pictureType = pictureType
        self.mimeType = mimeType
        self.description = description
        self.width = width
        self.height = height
        self.depth = depth
        self.colors = colors
        self.data = data
    }

    public init(payload: [UInt8]) throws {
        var r = ByteReader(payload)
        pictureType = try r.u32BE()
        mimeType = try r.ascii(Int(try r.u32BE()))
        description = String(decoding: try r.bytes(Int(try r.u32BE())), as: UTF8.self)
        width = try r.u32BE()
        height = try r.u32BE()
        depth = try r.u32BE()
        colors = try r.u32BE()
        data = try r.bytes(Int(try r.u32BE()))
    }

    public var payload: [UInt8] {
        var w = ByteWriter(reservingCapacity: 32 + data.count)
        w.u32BE(pictureType)
        let mime = Array(mimeType.utf8)
        w.u32BE(UInt32(mime.count)); w.append(mime)
        let desc = Array(description.utf8)
        w.u32BE(UInt32(desc.count)); w.append(desc)
        w.u32BE(width); w.u32BE(height); w.u32BE(depth); w.u32BE(colors)
        w.u32BE(UInt32(data.count)); w.append(data)
        return w.bytes
    }

    public static func frontCover(data: Data, mimeType: String) -> FlacPicture {
        let size = ImageInfo.pixelSize(of: data)
        return FlacPicture(pictureType: 3, mimeType: mimeType, width: size?.width ?? 0,
                           height: size?.height ?? 0, data: [UInt8](data))
    }
}
