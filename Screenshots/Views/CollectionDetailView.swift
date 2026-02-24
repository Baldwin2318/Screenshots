import SwiftUI

struct CollectionDetailView: View {
    let collection: CollectionSummary
    let onDelete: (ScreenshotItem) -> Void

    @State private var selectedItem: ScreenshotItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(collection.count) screenshots")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                MosaicScreenshotGrid(
                    items: collection.items.sorted { $0.date > $1.date },
                    onTap: { selectedItem = $0 },
                    onDelete: onDelete
                )
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .padding(.top, 8)
        }
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedItem) { item in
            ScreenshotDetailView(item: item)
        }
    }
}
