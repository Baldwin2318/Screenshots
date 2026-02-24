import Foundation

enum AdaptiveLearningService {
    private static let topicScoresKey = "adaptive.topicScores.v1"

    static func recordTopicInteraction(_ topic: String, weight: Double = 1.0) {
        let normalized = normalize(topic)
        guard !normalized.isEmpty else { return }

        var scores = loadTopicScores()
        scores[normalized, default: 0] += weight
        saveTopicScores(scores)
    }

    static func score(forTopic topic: String) -> Double {
        let normalized = normalize(topic)
        guard !normalized.isEmpty else { return 0 }
        return loadTopicScores()[normalized, default: 0]
    }

    private static func loadTopicScores() -> [String: Double] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: topicScoresKey),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveTopicScores(_ scores: [String: Double]) {
        guard let data = try? JSONEncoder().encode(scores) else { return }
        UserDefaults.standard.set(data, forKey: topicScoresKey)
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
