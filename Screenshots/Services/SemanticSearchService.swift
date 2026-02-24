import Foundation
import NaturalLanguage

enum SemanticSearchService {
    private static let embedding = NLEmbedding.wordEmbedding(for: .english)

    static func matches(item: ScreenshotItem, query rawQuery: String) -> Bool {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return true }

        let searchableValues = ([item.title, item.extractedText, item.summaryText] + item.collectionTags + item.topicTags + item.mlLabels)
            .map { $0.lowercased() }

        if searchableValues.contains(where: { $0.contains(query) }) {
            return true
        }

        guard let embedding else { return false }

        let queryTokens = tokens(from: query)
        let itemTokens = tokens(from: searchableValues.joined(separator: " "))

        guard !queryTokens.isEmpty, !itemTokens.isEmpty else { return false }

        for queryToken in queryTokens {
            if itemTokens.contains(queryToken) { return true }

            let hasCloseNeighbor = itemTokens.contains { token in
                let distance = embedding.distance(between: queryToken, and: token)
                return distance < 0.75
            }
            if hasCloseNeighbor { return true }
        }

        return false
    }

    private static func tokens(from text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
