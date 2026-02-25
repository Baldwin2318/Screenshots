import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isSearching) private var isSearching

    @Query(sort: \ScreenshotItem.date, order: .reverse)
    private var screenshots: [ScreenshotItem]

    @StateObject private var viewModel = ScreenshotsViewModel()
    @StateObject private var syncService = PhotoLibrarySyncService()

    @State private var selectedScreenshot: ScreenshotItem?
    @State private var showSettings = false
    @State private var libraryChangeToken = UUID()
    @State private var showSyncPrompt = false
    @State private var showLocalDeleteNotice = false
    @State private var hasPromptedForCurrentSession = false
    @State private var storageUsedBytes: Int64 = 0
    @State private var cacheBytes: Int64 = 0
    @State private var searchHistoryCount = 0

    @AppStorage("autoImportEnabled") private var autoImportEnabled = true
    @AppStorage("syncOnAppOpenEnabled") private var syncOnAppOpenEnabled = true
    @AppStorage("backgroundSyncEnabled") private var backgroundSyncEnabled = true
    @AppStorage("smartSearchEnabled") private var smartSearchEnabled = true
    @AppStorage("saveSearchHistoryEnabled") private var saveSearchHistoryEnabled = true

    var body: some View {
        NavigationStack {
            ScrollView {
                screenshotsSection
                    .padding(.top, 10)
                    .padding(.bottom, 20)

                Spacer(minLength: 16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("All Screenshots")
            .searchable(
                text: Binding(
                    get: { viewModel.searchText },
                    set: { viewModel.setSearchText($0) }
                ),
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search screenshots"
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .animation(.easeInOut(duration: 0.2), value: isSearching)
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
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    autoImportEnabled: $autoImportEnabled,
                    syncOnAppOpenEnabled: $syncOnAppOpenEnabled,
                    backgroundSyncEnabled: $backgroundSyncEnabled,
                    smartSearchEnabled: $smartSearchEnabled,
                    saveSearchHistoryEnabled: $saveSearchHistoryEnabled,
                    lastSyncSummary: syncService.lastSummary,
                    syncProgressText: syncService.syncProgressText,
                    isSyncing: syncService.isSyncing,
                    isSyncPaused: syncService.isPaused,
                    storageUsedText: formatBytes(storageUsedBytes),
                    cacheSizeText: formatBytes(cacheBytes),
                    searchHistoryCount: searchHistoryCount,
                    runSyncNow: { Task { await syncNow(allowImport: true) } },
                    pauseSync: syncService.pauseSync,
                    resumeSync: syncService.resumeSync,
                    clearCache: { Task { await clearCacheAndRefresh() } },
                    clearSearchHistory: clearSearchHistory
                )
            }
            .alert("Sync screenshots now?", isPresented: $showSyncPrompt) {
                Button("Not now", role: .cancel) {}
                Button("Sync") {
                    Task { await syncNow(allowImport: true) }
                }
            } message: {
                Text("Do you want to import new screenshots from Photos for this app session?")
            }
            .alert("Removed from this app", isPresented: $showLocalDeleteNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Removed from this app. Original photo still in your Photos library.")
            }
            .onAppear {
                updateLibraryObservation()
                viewModel.configure(
                    screenshots: screenshots,
                    smartSearchEnabled: smartSearchEnabled,
                    saveSearchHistoryEnabled: saveSearchHistoryEnabled
                )
                Task {
                    await refreshStorageMetrics()
                    refreshSearchHistoryMetadata()
                    if syncOnAppOpenEnabled {
                        await syncNow(allowImport: false)
                    }
                }
            }
            .onDisappear {
                syncService.stopObserving()
            }
            .onChange(of: screenshots) { _, newValue in
                viewModel.updateScreenshots(newValue)
                Task { await refreshStorageMetrics() }
            }
            .onChange(of: smartSearchEnabled) { _, enabled in
                viewModel.setSmartSearchEnabled(enabled)
            }
            .onChange(of: viewModel.searchText) { _, _ in
                if saveSearchHistoryEnabled {
                    refreshSearchHistoryMetadata()
                }
            }
            .onChange(of: saveSearchHistoryEnabled) { _, enabled in
                viewModel.setSaveSearchHistoryEnabled(enabled)
            }
            .onChange(of: backgroundSyncEnabled) { _, _ in
                updateLibraryObservation()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    if syncOnAppOpenEnabled {
                        Task { await syncNow(allowImport: false) }
                    }
                    if syncOnAppOpenEnabled && !hasPromptedForCurrentSession {
                        showSyncPrompt = true
                        hasPromptedForCurrentSession = true
                    }
                } else if phase == .background {
                    hasPromptedForCurrentSession = false
                }
            }
            .onChange(of: libraryChangeToken) { _, _ in
                guard backgroundSyncEnabled else { return }
                Task { await syncNow(allowImport: autoImportEnabled) }
            }
        }
    }

    private var screenshotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Screenshots")
                    .font(.title2.bold())
                Spacer()
                if syncService.isSyncing && !isSearching {
                    ProgressView()
                        .scaleEffect(0.85)
                }
            }
            .padding(.horizontal)
            .opacity(isSearching ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isSearching)

            if viewModel.filteredScreenshots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(viewModel.searchText.isEmpty ? "No screenshots yet." : "No screenshots found.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                MosaicScreenshotGrid(
                    items: viewModel.filteredScreenshots,
                    onTap: openScreenshot,
                    onDelete: deleteScreenshot
                )
                .opacity(isSearching ? 0.98 : 1.0)
                .padding(.horizontal)
            }
        }
    }

    private func syncNow(allowImport: Bool) async {
        await syncService.syncIfNeeded(
            context: context,
            existingItems: screenshots,
            allowImport: allowImport
        )
    }

    private func deleteScreenshot(_ item: ScreenshotItem) {
        FileStore.deleteImage(filename: item.imagePath)
        context.delete(item)
        try? context.save()
        showLocalDeleteNotice = true
        Task { await refreshStorageMetrics() }
    }

    private func openScreenshot(_ item: ScreenshotItem) {
        selectedScreenshot = item
    }

    private func updateLibraryObservation() {
        if backgroundSyncEnabled {
            syncService.startObserving {
                libraryChangeToken = UUID()
            }
        } else {
            syncService.stopObserving()
        }
    }

    private func refreshSearchHistoryMetadata() {
        searchHistoryCount = SearchHistoryStore.count()
    }

    private func clearSearchHistory() {
        SearchHistoryStore.clear()
        refreshSearchHistoryMetadata()
    }

    private func refreshStorageMetrics() async {
        let result = await Task.detached(priority: .utility) {
            (
                StorageMetricsService.appStorageUsageBytes(),
                StorageMetricsService.cacheUsageBytes()
            )
        }.value

        await MainActor.run {
            storageUsedBytes = result.0
            cacheBytes = result.1
        }
    }

    private func clearCacheAndRefresh() async {
        await Task.detached(priority: .utility) {
            StorageMetricsService.clearCache()
        }.value
        await refreshStorageMetrics()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}
