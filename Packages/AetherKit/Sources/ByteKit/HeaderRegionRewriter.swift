public import Foundation

/// Replaces the leading region `[0, oldLength)` of a file (a tag/metadata header) without loading the audio.
/// - Same length: overwrites in place (no copy, inode preserved — fastest path, used whenever padding allows).
/// - Different length: streams `newHeader + tail` into a sibling temp file in 1 MiB chunks and swaps it in atomically.
public enum HeaderRegionRewriter {
    public static func replace(fileAt url: URL, oldLength: Int, with newHeader: [UInt8]) throws {
        if newHeader.count == oldLength {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: newHeader)
            try handle.synchronize()
            return
        }

        let temp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).aether-tmp")
        let fm = FileManager.default
        guard fm.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let output = try FileHandle(forWritingTo: temp)
            let input = try FileHandle(forReadingFrom: url)
            try output.write(contentsOf: newHeader)
            try input.seek(toOffset: UInt64(oldLength))
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            try output.close()
            try input.close()
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
