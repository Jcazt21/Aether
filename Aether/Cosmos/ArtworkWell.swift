import SwiftUI
import TagKit
import UniformTypeIdentifiers

struct ArtworkWell: View {
    @Bindable var draft: TagDraft
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var isTargeted = false
    @State private var isImporting = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Tokens.surface)
            if let image {
                Image(decorative: image, scale: displayScale).resizable().scaledToFill()
            } else {
                Image(systemName: draft.artworkIsMixed ? "square.stack" : "photo")
                    .font(.title).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 180, height: 180)
        .clipShape(.rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(Tokens.hairline), lineWidth: isTargeted ? 2 : 1))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, let data = try? Data(contentsOf: url), let art = ArtworkProcessor.prepare(data) else { return false }
            draft.artwork = .set(art)
            return true
        } isTargeted: { isTargeted = $0 }
        .contextMenu {
            Button("Elegir imagen…") { isImporting = true }
            Button("Quitar portada", role: .destructive) { draft.artwork = .removed }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result, let data = try? Data(contentsOf: url), let art = ArtworkProcessor.prepare(data) {
                draft.artwork = .set(art)
            }
        }
        .task(id: artworkIdentity) {
            let data: Data? = switch draft.artwork {
            case .set(let art): art.data
            case .removed: nil
            case .unchanged: draft.currentArtwork?.data
            }
            image = await Task.detached(priority: .userInitiated) { data.flatMap { ArtworkProcessor.thumbnail($0, maxPixel: 360) } }.value
        }
        .accessibilityLabel("Portada")
    }

    private var artworkIdentity: Int {
        switch draft.artwork {
        case .unchanged: draft.currentArtwork?.data.hashValue ?? 0
        case .set(let art): art.data.hashValue
        case .removed: -1
        }
    }
}
