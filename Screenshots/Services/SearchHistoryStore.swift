import Foundation

enum SearchHistoryStore {
    private static let key = "search.history.v1"
    private static let maxEntries = 30

    static func save(query raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return }

        var items = history()
        items.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        items.insert(query, at: 0)
        if items.count > maxEntries {
            items = Array(items.prefix(maxEntries))
        }

        UserDefaults.standard.set(items, forKey: key)
    }

    static func history() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func count() -> Int {
        history().count
    }
}
