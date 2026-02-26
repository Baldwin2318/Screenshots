import Accelerate
import Foundation

actor SearchIndexService {
    private struct IndexedDocument: Sendable {
        let id: UUID
        let sortDate: TimeInterval
        let searchableText: String
        let tokens: [String]
        let imageEmbedding: [Float]?
    }

    private let ranking = SearchRankingConfig.default
    private var documents: [UUID: IndexedDocument] = [:]
    private var orderedIds: [UUID] = []
    private var cachedResults: [String: [UUID]] = [:]
    private var cacheOrder: [String] = []
    private var lastFingerprint = 0

    func reindexIfNeeded(with snapshots: [SearchIndexSnapshot]) {
        let fingerprint = Self.fingerprint(for: snapshots)
        guard fingerprint != lastFingerprint else { return }

        let sorted = snapshots.sorted { $0.sortDate > $1.sortDate }
        var newDocuments: [UUID: IndexedDocument] = [:]
        newDocuments.reserveCapacity(sorted.count)

        for snapshot in sorted {
            let searchableText = Self.normalize([
                snapshot.title,
                snapshot.extractedText,
                snapshot.summaryText,
                snapshot.labels.joined(separator: " ")
            ].joined(separator: " "))

            let rawTokens = Self.tokens(from: searchableText)
            let compactTokens = Array(Set(rawTokens)).prefix(ranking.maxIndexedTokensPerDocument)
            let decodedEmbedding = snapshot.imageEmbedding.flatMap(EmbeddingCodec.decodeNormalizedVector(from:))

            newDocuments[snapshot.id] = IndexedDocument(
                id: snapshot.id,
                sortDate: snapshot.sortDate,
                searchableText: searchableText,
                tokens: Array(compactTokens),
                imageEmbedding: decodedEmbedding
            )
        }

        documents = newDocuments
        orderedIds = sorted.map(\.id)
        lastFingerprint = fingerprint
        cachedResults.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    func search(query rawQuery: String) async -> [UUID] {
        let query = Self.normalize(rawQuery)
        if query.isEmpty { return orderedIds }

        if let cached = cachedResults[query] {
            return cached
        }

        let lexicalIds = lexicalSearch(query: query)
        let semanticIds = await semanticSearch(query: query) ?? []
        let merged = Self.mergeResults(semanticIds: semanticIds, lexicalIds: lexicalIds)
        let final = merged.isEmpty ? lexicalIds : merged

        setCache(final, for: query)
        return final
    }

    private func lexicalSearch(query: String) -> [UUID] {
        let queryTokens = Self.tokens(from: query)
        guard !queryTokens.isEmpty else { return orderedIds }

        var scored: [(id: UUID, score: Int, date: TimeInterval)] = []
        scored.reserveCapacity(documents.count)

        for id in orderedIds {
            guard let document = documents[id] else { continue }
            let score = Self.lexicalScore(document: document, query: query, queryTokens: queryTokens)
            if score > 0 {
                scored.append((id: document.id, score: score, date: document.sortDate))
            }
        }

        scored.sort {
            if $0.score == $1.score { return $0.date > $1.date }
            return $0.score > $1.score
        }

        return scored.map(\.id)
    }

    private func semanticSearch(query: String) async -> [UUID]? {
        let textVector = await CLIPEmbeddingService.shared.textEmbedding(for: query)
        guard let textVector, !textVector.isEmpty else { return nil }

        var scored: [(id: UUID, score: Float, date: TimeInterval)] = []
        scored.reserveCapacity(documents.count)

        for id in orderedIds {
            guard let document = documents[id], let imageVector = document.imageEmbedding else { continue }
            let score = Self.cosineSimilarity(lhs: textVector, rhs: imageVector)
            if score >= ranking.semanticAcceptanceThreshold {
                scored.append((id: id, score: score, date: document.sortDate))
            }
        }

        guard !scored.isEmpty else { return nil }

        scored.sort {
            if abs($0.score - $1.score) < ranking.semanticTieEpsilon {
                return $0.date > $1.date
            }
            return $0.score > $1.score
        }

        return scored.map(\.id)
    }

    private func setCache(_ ids: [UUID], for query: String) {
        cachedResults[query] = ids
        cacheOrder.removeAll { $0 == query }
        cacheOrder.append(query)

        if cacheOrder.count > ranking.maxCacheEntries, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cachedResults.removeValue(forKey: oldest)
        }
    }

    private static func mergeResults(semanticIds: [UUID], lexicalIds: [UUID]) -> [UUID] {
        guard !semanticIds.isEmpty else { return lexicalIds }
        guard !lexicalIds.isEmpty else { return semanticIds }

        var merged: [UUID] = []
        merged.reserveCapacity(max(semanticIds.count, lexicalIds.count))
        var seen = Set<UUID>()
        seen.reserveCapacity(semanticIds.count + lexicalIds.count)

        for id in semanticIds where seen.insert(id).inserted {
            merged.append(id)
        }
        for id in lexicalIds where seen.insert(id).inserted {
            merged.append(id)
        }

        return merged
    }

    private static func cosineSimilarity(lhs: [Float], rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var dot: Float = 0
        lhs.withUnsafeBufferPointer { lp in
            rhs.withUnsafeBufferPointer { rp in
                vDSP_dotpr(lp.baseAddress!, 1, rp.baseAddress!, 1, &dot, vDSP_Length(lhs.count))
            }
        }
        return dot
    }

    private static func lexicalScore(document: IndexedDocument, query: String, queryTokens: [String]) -> Int {
        var score = 0

        if document.searchableText.contains(query) {
            score += 85
        }

        for queryToken in queryTokens {
            if document.tokens.contains(queryToken) {
                score += 24
                continue
            }

            let hasPrefix = document.tokens.contains { token in
                token.hasPrefix(queryToken) || queryToken.hasPrefix(token)
            }
            if hasPrefix {
                score += 14
                continue
            }

            if queryToken.count >= 4 {
                let hasFuzzy = document.tokens.contains { token in
                    let delta = abs(token.count - queryToken.count)
                    guard delta <= 1 else { return false }
                    return boundedLevenshtein(token, queryToken, maxDistance: 1) <= 1
                }
                if hasFuzzy {
                    score += 10
                }
            }
        }

        return score
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(from value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func fingerprint(for snapshots: [SearchIndexSnapshot]) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshots.count)

        for snapshot in snapshots {
            hasher.combine(snapshot.id)
            hasher.combine(Int(snapshot.sortDate))
            hasher.combine(snapshot.title)
            hasher.combine(snapshot.extractedText.prefix(64))
            hasher.combine(snapshot.summaryText.prefix(64))
            hasher.combine(snapshot.labels.joined(separator: "|"))
            if let embedding = snapshot.imageEmbedding {
                hasher.combine(embedding.count)
                hasher.combine(embedding.prefix(64))
            } else {
                hasher.combine(0)
            }
        }

        return hasher.finalize()
    }

    private static func boundedLevenshtein(_ lhs: String, _ rhs: String, maxDistance: Int) -> Int {
        if lhs == rhs { return 0 }

        let left = Array(lhs)
        let right = Array(rhs)

        if abs(left.count - right.count) > maxDistance {
            return maxDistance + 1
        }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for i in 1...left.count {
            current[0] = i
            var rowMin = current[0]

            for j in 1...right.count {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                let insertion = current[j - 1] + 1
                let deletion = previous[j] + 1

                let best = min(substitution, insertion, deletion)
                current[j] = best
                rowMin = min(rowMin, best)
            }

            if rowMin > maxDistance {
                return maxDistance + 1
            }
            swap(&previous, &current)
        }

        return previous[right.count]
    }
}
