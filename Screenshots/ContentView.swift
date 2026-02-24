import SwiftUI
import SwiftData
import PhotosUI

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \ScreenshotItem.date, order: .reverse)
    private var screenshots: [ScreenshotItem]

    @StateObject private var viewModel = ScreenshotsViewModel()
    @StateObject private var syncService = PhotoLibrarySyncService()

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedScreenshot: ScreenshotItem?
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var libraryChangeToken = UUID()
    @State private var showActionButtons = false
    @State private var showSyncPrompt = false
    @State private var hasPromptedForCurrentSession = false

    @AppStorage("autoImportEnabled") private var autoImportEnabled = true
    @AppStorage("smartSearchEnabled") private var smartSearchEnabled = true

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    screenshotsSection
                        .padding(.top, 10)
                        .padding(.bottom, 20)

                    Spacer(minLength: 110)
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
                    runSyncNow: { Task { await syncNow() } },
                    pauseSync: syncService.pauseSync,
                    resumeSync: syncService.resumeSync
                )
            }
            .alert("Sync screenshots now?", isPresented: $showSyncPrompt) {
                Button("Not now", role: .cancel) {}
                Button("Sync") {
                    Task { await syncNow() }
                }
            } message: {
                Text("Do you want to import new screenshots from Photos for this app session?")
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
                viewModel.configure(screenshots: screenshots, smartSearchEnabled: smartSearchEnabled)
            }
            .onDisappear {
                syncService.stopObserving()
            }
            .onChange(of: screenshots) { _, newValue in
                viewModel.updateScreenshots(newValue)
            }
            .onChange(of: smartSearchEnabled) { _, enabled in
                viewModel.setSmartSearchEnabled(enabled)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    if !hasPromptedForCurrentSession {
                        showSyncPrompt = true
                        hasPromptedForCurrentSession = true
                    }
                } else if phase == .background {
                    hasPromptedForCurrentSession = false
                }
            }
            .onChange(of: libraryChangeToken) { _, _ in
                guard autoImportEnabled else { return }
                Task { await syncNow() }
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

            if viewModel.filteredScreenshots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(viewModel.searchText.isEmpty ? "No screenshots yet." : "No matches found.")
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

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(
                        "Search screenshots",
                        text: Binding(
                            get: { viewModel.searchText },
                            set: { viewModel.setSearchText($0) }
                        )
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.setSearchText("")
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

    private func syncNow() async {
        await syncService.syncIfNeeded(
            context: context,
            existingItems: screenshots,
            autoImportEnabled: autoImportEnabled
        )
    }

    private func saveManualImage(_ image: UIImage) async {
        let classification = await ScreenshotClassifier.classify(image: image)
        let filename = await Task.detached(priority: .userInitiated) {
            FileStore.saveImage(image)
        }.value

        guard let filename else { return }

        let item = ScreenshotItem(
            title: "Manual \(Date.now.formatted(date: .abbreviated, time: .shortened))",
            date: .now,
            imagePath: filename,
            collectionTags: [],
            topicTags: [],
            mlLabels: classification.labels,
            extractedText: classification.extractedText,
            summaryText: "",
            sourceAssetId: nil
        )

        context.insert(item)
        try? context.save()
    }

    private func deleteScreenshot(_ item: ScreenshotItem) {
        FileStore.deleteImage(filename: item.imagePath)
        context.delete(item)
        try? context.save()
    }

    private func openScreenshot(_ item: ScreenshotItem) {
        selectedScreenshot = item
    }
}
