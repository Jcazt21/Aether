import Foundation

extension TrackTags {
    public init(id3 tag: ID3Tag) {
        self.init(
            title: tag.text("TIT2"),
            artist: tag.text("TPE1"),
            album: tag.text("TALB"),
            albumArtist: tag.text("TPE2"),
            genre: tag.text("TCON").map(Self.stripNumericGenre),
            comment: Self.comment(in: tag),
            label: tag.text("TPUB"),
            key: tag.text("TKEY"),
            isrc: tag.text("TSRC"),
            composer: tag.text("TCOM"),
            remixer: tag.text("TPE4"),
            year: tag.text("TDRC") ?? tag.text("TYER"),
            bpm: tag.text("TBPM").flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) },
            trackNumber: tag.text("TRCK").flatMap(TrackTags.leadingInt),
            discNumber: tag.text("TPOS").flatMap(TrackTags.leadingInt),
            artwork: Self.frontCover(in: tag))
    }

    public func apply(to tag: inout ID3Tag) {
        tag.setText("TIT2", title)
        tag.setText("TPE1", artist)
        tag.setText("TALB", album)
        tag.setText("TPE2", albumArtist)
        tag.setText("TCON", genre)
        tag.setText("TPUB", label)
        tag.setText("TKEY", key)
        tag.setText("TSRC", isrc)
        tag.setText("TCOM", composer)
        tag.setText("TPE4", remixer)
        tag.setText("TBPM", bpm.map(TrackTags.formatBPM))
        tag.setText("TRCK", trackNumber.map(String.init))
        tag.setText("TPOS", discNumber.map(String.init))

        let isV4 = tag.majorVersion == 4
        let yearValue = isV4 ? year : year.map { String($0.prefix(4)) }
        let yearPosition = tag.frames.firstIndex { $0.id == "TDRC" || $0.id == "TYER" }
        tag.remove("TDRC")
        tag.remove("TYER")
        if let yearValue = yearValue?.nilIfBlank {
            tag.frames.insert(ID3Frame(id: isV4 ? "TDRC" : "TYER", flags: 0, payload: ID3Text.encode(yearValue)),
                              at: min(yearPosition ?? tag.frames.count, tag.frames.count))
        }

        tag.frames.removeAll { $0.id == "COMM" && Self.commentDescriptionIsEmpty($0, major: tag.majorVersion) }
        if let comment = comment?.nilIfBlank {
            let text = ID3Text.encode(comment)
            let encoding = text[0]
            let payload = [encoding] + Array("eng".utf8) + ID3Text.terminator(for: encoding)
                + (encoding == 1 ? [0xFF, 0xFE] : []) + text.dropFirst(encoding == 1 ? 3 : 1)
            tag.frames.append(ID3Frame(id: "COMM", flags: 0, payload: payload))
        }

        tag.frames.removeAll { $0.id == "APIC" && Self.pictureType($0, major: tag.majorVersion) == 3 }
        if let art = artwork {
            let payload: [UInt8] = [0] + Array(art.mimeType.utf8) + [0] + [3] + [0] + [UInt8](art.data)
            tag.frames.append(ID3Frame(id: "APIC", flags: 0, payload: payload))
        }
    }

    private static func stripNumericGenre(_ genre: String) -> String {
        guard genre.hasPrefix("("), let close = genre.firstIndex(of: ")") else { return genre }
        let rest = genre[genre.index(after: close)...]
        return rest.isEmpty ? genre : String(rest)
    }

    private static func commentParts(_ frame: ID3Frame, major: UInt8) -> (description: String, text: String)? {
        let c = frame.content(major: major)
        guard c.count >= 4 else { return nil }
        let encoding = c[0]
        let (desc, rest) = ID3Text.splitTerminated(c[4...], encoding: encoding)
        let text = ID3Text.decodeString(Array(rest), encoding: encoding)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        return (ID3Text.decodeString(desc, encoding: encoding) ?? "", text ?? "")
    }

    private static func commentDescriptionIsEmpty(_ frame: ID3Frame, major: UInt8) -> Bool {
        commentParts(frame, major: major)?.description.isEmpty ?? true
    }

    private static func comment(in tag: ID3Tag) -> String? {
        let comments = tag.frames.filter { $0.id == "COMM" }.compactMap { commentParts($0, major: tag.majorVersion) }
        return (comments.first { $0.description.isEmpty } ?? comments.first)?.text.nilIfBlank
    }

    private static func pictureParts(_ frame: ID3Frame, major: UInt8) -> (mime: String, type: UInt8, data: [UInt8])? {
        let c = frame.content(major: major)
        guard let encoding = c.first, let mimeEnd = c.dropFirst().firstIndex(of: 0), mimeEnd + 1 < c.count else { return nil }
        let mime = String(decoding: c[1..<mimeEnd], as: UTF8.self)
        let type = c[mimeEnd + 1]
        let (_, data) = ID3Text.splitTerminated(c[(mimeEnd + 2)...], encoding: encoding)
        return (mime.isEmpty ? "image/jpeg" : mime, type, Array(data))
    }

    private static func pictureType(_ frame: ID3Frame, major: UInt8) -> UInt8? { pictureParts(frame, major: major)?.type }

    private static func frontCover(in tag: ID3Tag) -> Artwork? {
        let pictures = tag.frames.filter { $0.id == "APIC" }.compactMap { pictureParts($0, major: tag.majorVersion) }
        return (pictures.first { $0.type == 3 } ?? pictures.first).map { Artwork(data: Data($0.data), mimeType: $0.mime) }
    }
}
