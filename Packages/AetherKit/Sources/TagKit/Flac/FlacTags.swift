public import Foundation

extension TrackTags {
    public init(vorbis v: VorbisComment, frontCover: FlacPicture?) {
        self.init(
            title: v.first("TITLE")?.nilIfBlank,
            artist: v.values("ARTIST").joined(separator: ", ").nilIfBlank,
            album: v.first("ALBUM")?.nilIfBlank,
            albumArtist: (v.first("ALBUMARTIST") ?? v.first("ALBUM ARTIST"))?.nilIfBlank,
            genre: v.first("GENRE")?.nilIfBlank,
            comment: (v.first("COMMENT") ?? v.first("DESCRIPTION"))?.nilIfBlank,
            label: (v.first("LABEL") ?? v.first("ORGANIZATION") ?? v.first("PUBLISHER"))?.nilIfBlank,
            key: (v.first("INITIALKEY") ?? v.first("KEY"))?.nilIfBlank,
            isrc: v.first("ISRC")?.nilIfBlank,
            composer: v.first("COMPOSER")?.nilIfBlank,
            remixer: (v.first("REMIXER") ?? v.first("MIXARTIST"))?.nilIfBlank,
            year: (v.first("DATE") ?? v.first("YEAR"))?.nilIfBlank,
            bpm: v.first("BPM").flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) },
            trackNumber: v.first("TRACKNUMBER").flatMap(TrackTags.leadingInt),
            discNumber: v.first("DISCNUMBER").flatMap(TrackTags.leadingInt),
            artwork: frontCover.map { Artwork(data: Data($0.data), mimeType: $0.mimeType) })
    }

    /// Writes managed keys only; unknown keys (Serato, MIK, ReplayGain…) are untouched.
    public func apply(to v: inout VorbisComment) {
        v.set("TITLE", title)
        v.set("ARTIST", artist)
        v.set("ALBUM", album)
        v.set("ALBUMARTIST", albumArtist)
        v.set("GENRE", genre)
        v.set("COMMENT", comment)
        v.set("LABEL", label)
        v.set("ORGANIZATION", label)
        v.set("INITIALKEY", key)
        v.set("ISRC", isrc)
        v.set("COMPOSER", composer)
        v.set("REMIXER", remixer)
        v.set("DATE", year)
        v.set("YEAR", nil)
        v.set("BPM", bpm.map(TrackTags.formatBPM))
        v.set("TRACKNUMBER", trackNumber.map(String.init))
        v.set("DISCNUMBER", discNumber.map(String.init))
    }
}

public enum FlacTags {
    public static func read(_ url: URL) throws -> (tags: TrackTags, streamInfo: StreamInfo, header: FlacHeader) {
        let header = try FlacMetadataIO.read(url)
        let vorbis = try header.blocks(ofType: FlacBlockType.vorbisComment).first.map { try VorbisComment(payload: $0.payload) }
            ?? VorbisComment()
        let pictures = try header.blocks(ofType: FlacBlockType.picture).map { try FlacPicture(payload: $0.payload) }
        let front = pictures.first { $0.pictureType == 3 } ?? pictures.first
        return (TrackTags(vorbis: vorbis, frontCover: front), try header.streamInfo(), header)
    }

    /// Block order: STREAMINFO, other non-tag blocks, VORBIS_COMMENT, non-front pictures, front cover. No padding.
    public static func blocks(applying tags: TrackTags, to header: FlacHeader,
                              extraFields: [String: String] = [:]) throws -> [FlacBlock] {
        var vorbis = try header.blocks(ofType: FlacBlockType.vorbisComment).first.map { try VorbisComment(payload: $0.payload) }
            ?? VorbisComment()
        tags.apply(to: &vorbis)
        for (key, value) in extraFields.sorted(by: { $0.key < $1.key }) { vorbis.set(key, value) }

        let streamInfo = header.blocks[0]
        let others = header.blocks.dropFirst().filter {
            ![FlacBlockType.vorbisComment, FlacBlockType.padding, FlacBlockType.picture].contains($0.type)
        }
        let keptPictures = try header.blocks(ofType: FlacBlockType.picture).filter {
            try FlacPicture(payload: $0.payload).pictureType != 3
        }
        var result = [streamInfo] + others + [FlacBlock(type: FlacBlockType.vorbisComment, payload: vorbis.payload)] + keptPictures
        if let art = tags.artwork {
            result.append(FlacBlock(type: FlacBlockType.picture,
                                    payload: FlacPicture.frontCover(data: art.data, mimeType: art.mimeType).payload))
        }
        return result
    }

    public static func write(_ tags: TrackTags, to url: URL, extraFields: [String: String] = [:]) throws {
        let header = try FlacMetadataIO.read(url)
        try FlacMetadataIO.write(try blocks(applying: tags, to: header, extraFields: extraFields), to: url)
    }
}
