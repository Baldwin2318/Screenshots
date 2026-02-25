import Combine
import Foundation
import SwiftData

@MainActor
final class ScreenshotsViewModel: ObservableObject {
    @Published private(set) var filteredScreenshots: [ScreenshotItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchText = ""

    private var allScreenshots: [ScreenshotItem] = []
    private var smartSearchEnabled = true
    private var saveSearchHistoryEnabled = true
    private var searchTask: Task<Void, Never>?
    private var revision = 0

    private let indexService = SearchIndexService()

    deinit {
        searchTask?.cancel()
    }

    func configure(
        screenshots: [ScreenshotItem],
        smartSearchEnabled: Bool,
        saveSearchHistoryEnabled: Bool
    ) {
        self.smartSearchEnabled = smartSearchEnabled
        self.saveSearchHistoryEnabled = saveSearchHistoryEnabled
        allScreenshots = screenshots
        revision += 1
        let targetRevision = revision
        rebuildSearchIndex(using: screenshots)
        scheduleSearch(revision: targetRevision, debounceNanoseconds: 0)
    }

    func updateScreenshots(_ screenshots: [ScreenshotItem]) {
        allScreenshots = screenshots
        revision += 1
        let targetRevision = revision
        rebuildSearchIndex(using: screenshots)
        scheduleSearch(revision: targetRevision, debounceNanoseconds: 0)
    }

    func setSmartSearchEnabled(_ enabled: Bool) {
        guard smartSearchEnabled != enabled else { return }
        smartSearchEnabled = enabled
        revision += 1
        scheduleSearch(revision: revision, debounceNanoseconds: 0)
    }

    func setSearchText(_ text: String) {
        searchText = text
        revision += 1
        scheduleSearch(revision: revision, debounceNanoseconds: 120_000_000)
    }

    func setSaveSearchHistoryEnabled(_ enabled: Bool) {
        saveSearchHistoryEnabled = enabled
    }

    func commitSearchHistory() {
        guard saveSearchHistoryEnabled else { return }
        SearchHistoryStore.save(query: searchText)
    }

    private func rebuildSearchIndex(using screenshots: [ScreenshotItem]) {
        let snapshots = screenshots.map {
            SearchIndexSnapshot(
                id: $0.id,
                sortDate: $0.date.timeIntervalSince1970,
                title: $0.title,
                extractedText: $0.extractedText,
                summaryText: $0.summaryText,
                labels: $0.mlLabels
            )
        }

        Task.detached(priority: .utility) { [indexService] in
            await indexService.reindexIfNeeded(with: snapshots)
        }
    }

    private func scheduleSearch(revision: Int, debounceNanoseconds: UInt64) {
        searchTask?.cancel()

        let query = searchText
        let screenshots = allScreenshots
        let smartSearchEnabled = smartSearchEnabled
        let saveSearchHistoryEnabled = saveSearchHistoryEnabled
        isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        searchTask = Task(priority: .userInitiated) {
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            if Task.isCancelled { return }

            let results: [ScreenshotItem]
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

            if normalizedQuery.isEmpty {
                results = screenshots
            } else if smartSearchEnabled {
                let ids = await indexService.search(query: query)
                let byId = Dictionary(uniqueKeysWithValues: screenshots.map { ($0.id, $0) })
                let indexedResults = ids.compactMap { byId[$0] }
                results = indexedResults.isEmpty ? Self.defaultFilter(in: screenshots, query: normalizedQuery) : indexedResults
            } else {
                results = Self.defaultFilter(in: screenshots, query: normalizedQuery)
            }

            if saveSearchHistoryEnabled, !normalizedQuery.isEmpty {
                SearchHistoryStore.save(query: normalizedQuery)
            }

            await MainActor.run {
                guard revision == self.revision else { return }
                self.filteredScreenshots = results
                self.isSearching = false
            }
        }
    }

    private static func defaultFilter(in screenshots: [ScreenshotItem], query: String) -> [ScreenshotItem] {
        screenshots.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
            || item.mlLabels.joined(separator: " ").localizedCaseInsensitiveContains(query)
            || item.extractedText.localizedCaseInsensitiveContains(query)
            || item.summaryText.localizedCaseInsensitiveContains(query)
        }
    }
}
