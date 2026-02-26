import Foundation
import SwiftData
import UIKit

@Model
final class ScreenshotItem {
    var id: UUID = UUID()
    var title: String = ""
    var date: Date = Date()
    var imagePath: String = ""
    var collectionTags: [String] = []
    var topicTags: [String] = []
    var mlLabels: [String] = []
    var extractedText: String = ""
    var summaryText: String = ""
    var sourceAssetId: String?
    var clipEmbedding: Data?

    init(
        title: String,
        date: Date = .now,
        imagePath: String,
        collectionTags: [String],
        topicTags: [String] = [],
        mlLabels: [String] = [],
        extractedText: String = "",
        summaryText: String = "",
        sourceAssetId: String? = nil,
        clipEmbedding: Data? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.date = date
        self.imagePath = imagePath
        self.collectionTags = collectionTags
        self.topicTags = topicTags
        self.mlLabels = mlLabels
        self.extractedText = extractedText
        self.summaryText = summaryText
        self.sourceAssetId = sourceAssetId
        self.clipEmbedding = clipEmbedding
    }

    var uiImage: UIImage? {
        let url = FileStore.documentsURL.appendingPathComponent(imagePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}
