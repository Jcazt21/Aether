enum ReviewFilter: String, Hashable, CaseIterable {
    case untagged, duplicates, lossy

    var title: String {
        switch self {
        case .untagged: "Sin tags"
        case .duplicates: "Duplicados"
        case .lossy: "Lossy"
        }
    }

    var symbol: String {
        switch self {
        case .untagged: "tag.slash"
        case .duplicates: "square.on.square"
        case .lossy: "waveform.badge.minus"
        }
    }
}

enum Route: Hashable {
    case harvesterSearch
    case harvesterQueue
    case harvesterHistory
    case cosmosAll
    case cosmosFolder(String)
    case cosmosInbox
    case cosmosReview(ReviewFilter)
}
