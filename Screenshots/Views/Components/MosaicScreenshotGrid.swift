import SwiftUI

struct MosaicScreenshotGrid: View {
    let items: [ScreenshotItem]
    let onTap: (ScreenshotItem) -> Void
    let onDelete: (ScreenshotItem) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(items, id: \.id) { item in
                Button {
                    onTap(item)
                } label: {
                    LocalFileImage(path: item.imagePath, contentMode: .fill)
                        .frame(height: 188)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        onDelete(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }
}
