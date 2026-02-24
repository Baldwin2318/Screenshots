import SwiftUI
import SwiftData

struct ScreenshotDetailView: View {
    let item: ScreenshotItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var isSummarizing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LocalFileImage(path: item.imagePath, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal)
                        .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title)
                            .font(.title3.bold())

                        Text(item.date.formatted(date: .complete, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Summary")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            if isSummarizing && item.summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                ProgressView()
                                    .scaleEffect(0.85)
                            } else {
                                Text(item.summaryText.isEmpty ? "No summary available yet." : item.summaryText)
                                    .font(.subheadline)
                            }
                        }

                        if !item.mlLabels.isEmpty {
                            Text("Detected Labels")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            WrappingTags(tags: Array(item.mlLabels.prefix(10)))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await ensureSummaryIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: FileStore.documentsURL.appendingPathComponent(item.imagePath)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private func ensureSummaryIfNeeded() async {
        if !item.summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        isSummarizing = true
        let generated = await AppleIntelligenceService.summarizeScreenshot(text: item.extractedText, labels: item.mlLabels)
        let finalSummary = generated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Summary not available yet."
            : generated
        await MainActor.run {
            item.summaryText = finalSummary
            try? context.save()
            isSummarizing = false
        }
    }
}

private struct WrappingTags: View {
    let tags: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Text(tag.capitalized)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground), in: Capsule())
            }
        }
    }
}
