import Foundation

struct SearchIndexSnapshot: Sendable {
    let id: UUID
    let sortDate: TimeInterval
    let title: String
    let extractedText: String
    let summaryText: String
    let labels: [String]
    let imageEmbedding: Data?
}

struct SearchRankingConfig: Sendable {
    let semanticAcceptanceThreshold: Float
    let semanticTieEpsilon: Float
    let maxCacheEntries: Int
    let maxIndexedTokensPerDocument: Int

    static let `default` = SearchRankingConfig(
        semanticAcceptanceThreshold: 0.14,
        semanticTieEpsilon: 0.0001,
        maxCacheEntries: 120,
        maxIndexedTokensPerDocument: 80
    )
}
