import SwiftUI

struct CollectionsListView: View {
    let collections: [CollectionSummary]
    let onDelete: (ScreenshotItem) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(collections) { collection in
                    NavigationLink {
                        CollectionDetailView(collection: collection, onDelete: onDelete)
                    } label: {
                        CollectionCard(collection: collection)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("Collections")
    }
}
