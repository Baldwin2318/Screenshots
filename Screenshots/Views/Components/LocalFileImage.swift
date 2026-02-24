import SwiftUI

struct LocalFileImage: View {
    let path: String
    let contentMode: ContentMode

    var body: some View {
        AsyncImage(url: FileStore.documentsURL.appendingPathComponent(path)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            case .empty:
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
            case .failure:
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            @unknown default:
                EmptyView()
            }
        }
    }
}
