import SwiftUI
import SwiftData
import PhotosUI

struct ContentView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \ScreenshotItem.date, order: .forward)
    private var screenshots: [ScreenshotItem]

    @StateObject private var syncService = PhotoLibrarySyncService()

    @State private var searchText = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedScreenshot: ScreenshotItem?
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var libraryChangeToken = UUID()
    @State private var showActionButtons = false
    @State private var selectedTopicTag: String?

    @AppStorage("autoImportEnabled") private var autoImportEnabled = true
    @AppStorage("smartSearchEnabled") private var smartSearchEnabled = true

    private var filteredScreenshots: [ScreenshotItem] {
        screenshots.filter { item in
            let searchMatches = smartSearchEnabled
                ? SemanticSearchService.matches(item: item, query: searchText)
                : defaultSearchMatch(for: item)

            guard searchMatches else { return false }

            if let selectedTopicTag, !selectedTopicTag.isEmpty {
                return item.topicTags.contains(where: { $0.caseInsensitiveCompare(selectedTopicTag) == .orderedSame })
            }
            return true
        }
    }

    private var topTopicTags: [String] {
        var counts: [String: Int] = [:]
        for item in screenshots {
            for tag in item.topicTags {
                let normalized = normalizeTag(tag)
                guard !normalized.isEmpty else { continue }
                counts[normalized, default: 0] += 1
            }
        }

        return counts
            .sorted {
                let left = Double($0.value) + AdaptiveLearningService.score(forTopic: $0.key)
                let right = Double($1.value) + AdaptiveLearningService.score(forTopic: $1.key)
                if left == right { return $0.key < $1.key }
                return left > right
            }
            .map(\.key)
            .prefix(12)
            .map { $0 }
    }

    private var searchSuggestions: [String] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Array((topTopicTags + collections.map(\.name)).prefix(10))
        }

        let query = searchText.lowercased()
        let pool = (topTopicTags + collections.map(\.name) + screenshots.flatMap(\.mlLabels))
            .map { normalizeTag($0) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var result: [String] = []

        for value in pool where value.lowercased().contains(query) {
            let key = value.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(value)
            if result.count >= 10 { break }
        }

        return result
    }

    private var collections: [CollectionSummary] {
        var grouped: [String: [ScreenshotItem]] = [:]

        for item in screenshots {
            let tags = item.collectionTags.isEmpty ? ["General"] : item.collectionTags
            for tag in tags {
                let normalized = normalizeTag(tag)
                let groupName = normalized.isEmpty ? "General" : normalized
                grouped[groupName, default: []].append(item)
            }
        }

        return grouped
            .map { CollectionSummary(name: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted {
                if $0.count == $1.count { return $0.name < $1.name }
                return $0.count > $1.count
            }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        collectionsSection
                        screenshotsSection
                        Spacer(minLength: 110)
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 20)
                }

                if showActionButtons {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showActionButtons = false
                            }
                        }
                }

                bottomSearchBar
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("All Screenshots")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(item: $selectedScreenshot) { item in
                ScreenshotDetailView(item: item)
            }
            .sheet(isPresented: $showCamera) {
                CameraView { image in
                    Task { await saveManualImage(image) }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    autoImportEnabled: $autoImportEnabled,
                    smartSearchEnabled: $smartSearchEnabled,
                    lastSyncSummary: syncService.lastSummary,
                    syncProgressText: syncService.syncProgressText,
                    isSyncing: syncService.isSyncing,
                    isSyncPaused: syncService.isPaused,
                    rebuildRecommendation: rebuildRecommendation,
                    runSyncNow: { Task { await syncNow() } },
                    pauseSync: syncService.pauseSync,
                    resumeSync: syncService.resumeSync,
                    rebuildCategories: { Task { await rebuildCategoriesFromML() } }
                )
            }
            .onChange(of: selectedPhoto) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await saveManualImage(image)
                    }
                    await MainActor.run { selectedPhoto = nil }
                }
            }
            .onAppear {
                syncService.startObserving {
                    libraryChangeToken = UUID()
                }
                Task { await syncNow() }
            }
            .onDisappear {
                syncService.stopObserving()
            }
            .onChange(of: libraryChangeToken) { _, _ in
                Task { await syncNow() }
            }
        }
    }

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                CollectionsListView(collections: collections, onDelete: deleteScreenshot)
            } label: {
                HStack {
                    Text("Collections")
                        .font(.title2.bold())
                    Spacer()
                    Text("See all")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
            .padding(.horizontal)

            if collections.isEmpty {
                Text(syncService.isSyncing ? "Importing screenshots..." : "Collections appear after screenshots are imported.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(collections.prefix(8)) { collection in
                            NavigationLink {
                                CollectionDetailView(collection: collection, onDelete: deleteScreenshot)
                            } label: {
                                CollectionCard(collection: collection)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private var screenshotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Screenshots")
                    .font(.title2.bold())
                Spacer()
                if syncService.isSyncing {
                    ProgressView()
                        .scaleEffect(0.85)
                }
            }
            .padding(.horizontal)

            if !topTopicTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            selectedTopicTag = nil
                            AdaptiveLearningService.recordTopicInteraction("all", weight: 0.1)
                        } label: {
                            Text("All")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(selectedTopicTag == nil ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        ForEach(topTopicTags, id: \.self) { tag in
                            Button {
                                selectedTopicTag = (selectedTopicTag == tag) ? nil : tag
                                AdaptiveLearningService.recordTopicInteraction(tag)
                            } label: {
                                Text(tag)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(selectedTopicTag == tag ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }

            if filteredScreenshots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(searchText.isEmpty ? "Waiting for screenshots..." : "No matches found.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                MosaicScreenshotGrid(
                    items: filteredScreenshots,
                    onTap: openScreenshot,
                    onDelete: deleteScreenshot
                )
                .padding(.horizontal)
            }
        }
    }

    private var bottomSearchBar: some View {
        VStack(spacing: 10) {
            if showActionButtons {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        Button {
                            showActionButtons = false
                            showCamera = true
                        } label: {
                            Label("Camera", systemImage: "camera.fill")
                                .font(.subheadline.bold())
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground), in: Capsule())
                        }

                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("Add Photos", systemImage: "photo.fill")
                                .font(.subheadline.bold())
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color(.secondarySystemBackground), in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .transition(.opacity)
            }

            if !searchSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(searchSuggestions, id: \.self) { suggestion in
                            Button {
                                searchText = suggestion
                                if topTopicTags.contains(where: { $0.caseInsensitiveCompare(suggestion) == .orderedSame }) {
                                    selectedTopicTag = suggestion
                                }
                                AdaptiveLearningService.recordTopicInteraction(suggestion, weight: 0.5)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkle.magnifyingglass")
                                        .font(.caption2)
                                    Text(suggestion)
                                        .font(.caption.bold())
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color(.secondarySystemBackground), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .transition(.opacity)
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search screenshots", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            selectedTopicTag = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: Capsule())

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showActionButtons.toggle()
                    }
                } label: {
                    Image(systemName: showActionButtons ? "xmark" : "plus")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.accentColor, in: Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func defaultSearchMatch(for item: ScreenshotItem) -> Bool {
        searchText.isEmpty
        || item.title.localizedCaseInsensitiveContains(searchText)
        || item.collectionTags.joined(separator: " ").localizedCaseInsensitiveContains(searchText)
        || item.topicTags.joined(separator: " ").localizedCaseInsensitiveContains(searchText)
        || item.extractedText.localizedCaseInsensitiveContains(searchText)
        || item.summaryText.localizedCaseInsensitiveContains(searchText)
    }

    private func syncNow() async {
        await syncService.syncIfNeeded(
            context: context,
            existingItems: screenshots,
            autoImportEnabled: autoImportEnabled
        )
    }

    private func saveManualImage(_ image: UIImage) async {
        let classification = await ScreenshotClassifier.classify(image: image)
        let aiCollections = await AppleIntelligenceService.generateCollectionNames(
            text: classification.extractedText,
            labels: classification.labels
        )
        let aiTopics = await AppleIntelligenceService.generateTopicTags(
            text: classification.extractedText,
            labels: classification.labels
        )
        let normalizedCollections = AppleIntelligenceService.normalizeTagList(
            aiCollections.isEmpty ? classification.categories : aiCollections,
            maxCount: 3
        )
        let normalizedTopics = AppleIntelligenceService.normalizeTagList(
            aiTopics.isEmpty ? classification.topicTags : aiTopics,
            maxCount: 8
        )
        guard let filename = FileStore.saveImage(image) else { return }

        let item = ScreenshotItem(
            title: "Manual \(Date.now.formatted(date: .abbreviated, time: .shortened))",
            date: .now,
            imagePath: filename,
            collectionTags: normalizedCollections.isEmpty ? ["Quick Notes"] : normalizedCollections,
            topicTags: normalizedTopics,
            mlLabels: classification.labels,
            extractedText: classification.extractedText,
            summaryText: "",
            sourceAssetId: nil
        )

        context.insert(item)
        try? context.save()
    }

    private func rebuildCategoriesFromML() async {
        for item in screenshots {
            guard let image = item.uiImage else { continue }
            let classification = await ScreenshotClassifier.classify(image: image)
            let aiCollections = await AppleIntelligenceService.generateCollectionNames(
                text: classification.extractedText,
                labels: classification.labels
            )
            let aiTopics = await AppleIntelligenceService.generateTopicTags(
                text: classification.extractedText,
                labels: classification.labels
            )
            let normalizedCollections = AppleIntelligenceService.normalizeTagList(
                aiCollections.isEmpty ? classification.categories : aiCollections,
                maxCount: 3
            )
            let normalizedTopics = AppleIntelligenceService.normalizeTagList(
                aiTopics.isEmpty ? classification.topicTags : aiTopics,
                maxCount: 8
            )
            item.collectionTags = normalizedCollections.isEmpty ? ["Quick Notes"] : normalizedCollections
            item.topicTags = normalizedTopics
            item.mlLabels = classification.labels
            item.extractedText = classification.extractedText
        }
        try? context.save()
        let defaults = UserDefaults.standard
        defaults.set(0, forKey: "ml.rebuild.pendingCount")
        defaults.set(Date.now.timeIntervalSince1970, forKey: "ml.rebuild.lastRun")
    }

    private func deleteScreenshot(_ item: ScreenshotItem) {
        FileStore.deleteImage(filename: item.imagePath)
        context.delete(item)
        try? context.save()
    }

    private func openScreenshot(_ item: ScreenshotItem) {
        selectedScreenshot = item
        item.topicTags.forEach { AdaptiveLearningService.recordTopicInteraction($0, weight: 0.25) }
        item.collectionTags.forEach { AdaptiveLearningService.recordTopicInteraction($0, weight: 0.15) }
    }

    private var rebuildRecommendation: String? {
        let defaults = UserDefaults.standard
        let pending = defaults.integer(forKey: "ml.rebuild.pendingCount")
        let lastRun = defaults.double(forKey: "ml.rebuild.lastRun")

        if pending >= 80 {
            return "Recommended: Rebuild categories now. \(pending) new screenshots were imported."
        }

        if lastRun > 0 {
            let days = Int((Date.now.timeIntervalSince1970 - lastRun) / 86_400)
            if days >= 14 && pending > 20 {
                return "Recommended: Rebuild categories. It has been \(days) days since the last rebuild."
            }
        } else if pending > 30 {
            return "Recommended: Run first category rebuild for better grouping quality."
        }

        return nil
    }

    private func normalizeTag(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
