import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleIntelligenceService {
    static func summarizeScreenshot(text: String, labels: [String]) async -> String {
        let compactText = normalize(text)
        let compactLabels = labels.prefix(12).joined(separator: ", ")
        let cacheKey = "summary|\(compactText.prefix(180))|\(compactLabels)"

        if let cached = await AIResponseCache.shared.summary(for: cacheKey) {
            return cached
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           SystemLanguageModel.default.availability == .available,
           consumeBudget(task: "summary", maxPerDay: 180) {
            do {
                let session = LanguageModelSession(instructions: "You summarize screenshots precisely in one sentence.")
                let prompt = """
                OCR Text:\n\(compactText.isEmpty ? "(none)" : compactText)\n\nVisual labels: \(compactLabels.isEmpty ? "(none)" : compactLabels)\n\nSummarize what this screenshot contains in one concise sentence.
                """
                let response = try await session.respond(to: prompt)
                let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !result.isEmpty {
                    await AIResponseCache.shared.setSummary(result, for: cacheKey)
                    return result
                }
            } catch {
                // Fall back below.
            }
        }
        #endif

        if !compactText.isEmpty {
            let first = compactText.split(separator: "\n").first.map(String.init) ?? compactText
            let fallback = String(first.prefix(140))
            await AIResponseCache.shared.setSummary(fallback, for: cacheKey)
            return fallback
        }

        if !compactLabels.isEmpty {
            let fallback = "Screenshot includes \(compactLabels)."
            await AIResponseCache.shared.setSummary(fallback, for: cacheKey)
            return fallback
        }

        let fallback = "Screenshot content recognized."
        await AIResponseCache.shared.setSummary(fallback, for: cacheKey)
        return fallback
    }

    static func generateCollectionNames(text: String, labels: [String]) async -> [String] {
        let compactText = normalize(text)
        let compactLabels = labels.prefix(14).joined(separator: ", ")

        let cacheKey = "collections|\(compactText.prefix(180))|\(compactLabels)"
        if let cached = await AIResponseCache.shared.list(for: cacheKey) {
            return cached
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           SystemLanguageModel.default.availability == .available,
           consumeBudget(task: "collections", maxPerDay: 160) {
            do {
                let session = LanguageModelSession(instructions: "You generate short, creative, practical screenshot collection names.")
                let prompt = """
                OCR Text:\n\(compactText.isEmpty ? "(none)" : compactText)\n\nVisual labels: \(compactLabels.isEmpty ? "(none)" : compactLabels)\n\nGenerate exactly 2 collection names, each 2-4 words, title case, no numbering.
                """
                let response = try await session.respond(to: prompt)
                let items = normalizeTagList(parseList(from: response.content), maxCount: 2)
                if !items.isEmpty {
                    let result = Array(items.prefix(2))
                    await AIResponseCache.shared.setList(result, for: cacheKey)
                    return result
                }
            } catch {
                // Fall back below.
            }
        }
        #endif

        let keywords = ScreenshotClassifier.extractKeywords(from: ([compactText] + labels).joined(separator: " "))
        if let first = keywords.first {
            let fallback = normalizeTagList(["\(ScreenshotClassifier.titleCase(first)) Ideas"], maxCount: 2)
            await AIResponseCache.shared.setList(fallback, for: cacheKey)
            return fallback
        }
        let fallback = ["Quick Notes"]
        await AIResponseCache.shared.setList(fallback, for: cacheKey)
        return fallback
    }

    static func generateTopicTags(text: String, labels: [String]) async -> [String] {
        let compactText = normalize(text)
        let compactLabels = labels.prefix(14).joined(separator: ", ")

        let cacheKey = "topics|\(compactText.prefix(180))|\(compactLabels)"
        if let cached = await AIResponseCache.shared.list(for: cacheKey) {
            return cached
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *),
           SystemLanguageModel.default.availability == .available,
           consumeBudget(task: "topics", maxPerDay: 220) {
            do {
                let session = LanguageModelSession(instructions: "You identify concise topical tags for screenshot grouping.")
                let prompt = """
                OCR Text:\n\(compactText.isEmpty ? "(none)" : compactText)\n\nVisual labels: \(compactLabels.isEmpty ? "(none)" : compactLabels)\n\nReturn 4 short topic tags (one or two words), no numbering.
                """
                let response = try await session.respond(to: prompt)
                let items = normalizeTagList(parseList(from: response.content), maxCount: 6)
                if !items.isEmpty {
                    let result = Array(items.prefix(6))
                    await AIResponseCache.shared.setList(result, for: cacheKey)
                    return result
                }
            } catch {
                // Fall back below.
            }
        }
        #endif

        let fallback = normalizeTagList(
            ScreenshotClassifier.extractKeywords(from: ([compactText] + labels).joined(separator: " ")),
            maxCount: 6
        )
        await AIResponseCache.shared.setList(fallback, for: cacheKey)
        return fallback
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    private static func parseList(from raw: String) -> [String] {
        raw
            .components(separatedBy: CharacterSet.newlines)
            .map {
                $0
                    .replacingOccurrences(of: "- ", with: "")
                    .replacingOccurrences(of: "• ", with: "")
                    .replacingOccurrences(of: "1. ", with: "")
                    .replacingOccurrences(of: "2. ", with: "")
                    .replacingOccurrences(of: "3. ", with: "")
                    .replacingOccurrences(of: "4. ", with: "")
                    .replacingOccurrences(of: "5. ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .flatMap { line in
                line.contains(",") ? line.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } : [line]
            }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "\"", with: "") }
    }

    static func normalizeTagList(_ values: [String], maxCount: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for raw in values {
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: "  ", with: " ")

            guard !cleaned.isEmpty else { continue }
            guard cleaned.count >= 2 && cleaned.count <= 28 else { continue }

            let normalized = cleaned
                .split(separator: " ")
                .map { $0.capitalized }
                .joined(separator: " ")

            let key = normalized.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(normalized)

            if result.count >= maxCount { break }
        }

        return result
    }

    private static func consumeBudget(task: String, maxPerDay: Int) -> Bool {
        let defaults = UserDefaults.standard
        let day = Date.now.formatted(.iso8601.year().month().day())
        let dayKey = "ai.budget.\(task).day"
        let countKey = "ai.budget.\(task).count"

        let currentDay = defaults.string(forKey: dayKey)
        if currentDay != day {
            defaults.set(day, forKey: dayKey)
            defaults.set(0, forKey: countKey)
        }

        let currentCount = defaults.integer(forKey: countKey)
        guard currentCount < maxPerDay else { return false }
        defaults.set(currentCount + 1, forKey: countKey)
        return true
    }
}

actor AIResponseCache {
    static let shared = AIResponseCache()

    private var summaries: [String: String] = [:]
    private var lists: [String: [String]] = [:]

    func summary(for key: String) -> String? {
        summaries[key]
    }

    func setSummary(_ value: String, for key: String) {
        summaries[key] = value
    }

    func list(for key: String) -> [String]? {
        lists[key]
    }

    func setList(_ value: [String], for key: String) {
        lists[key] = value
    }
}
