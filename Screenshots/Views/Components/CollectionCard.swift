import SwiftUI

struct CollectionCard: View {
    let collection: CollectionSummary

    private let cardW: CGFloat = 180
    private let cardH: CGFloat = 160

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))

            Text(collection.name)
                .font(.caption.bold())
                .lineLimit(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.systemBackground))
                )
                .padding(10)

            VStack {
                Spacer()
                HStack {
                    ZStack(alignment: .bottomLeading) {
                        let previews = Array(collection.items.prefix(3))
                        if previews.isEmpty {
                            Image(systemName: "photo.stack")
                                .foregroundStyle(.secondary)
                                .frame(width: 84, height: 104)
                        } else {
                            ForEach(Array(previews.enumerated()), id: \.offset) { index, item in
                                LocalFileImage(path: item.imagePath, contentMode: .fill)
                                    .frame(width: 72, height: 94)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .rotationEffect(.degrees(Double(index) * 6 - 5), anchor: .bottomLeading)
                                    .offset(x: CGFloat(index) * 7, y: CGFloat(index) * -4)
                                    .zIndex(Double(index))
                            }
                        }
                    }
                    .frame(height: 104)
                    .padding(.leading, 12)

                    Spacer()
                }
                .padding(.bottom, 12)
            }

            if collection.count > 0 {
                HStack {
                    Spacer()
                    Text("\(collection.count)")
                        .font(.caption2.bold())
                        .padding(6)
                        .background(Color.accentColor.opacity(0.16), in: Circle())
                        .padding(10)
                }
            }
        }
        .frame(width: cardW, height: cardH)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
