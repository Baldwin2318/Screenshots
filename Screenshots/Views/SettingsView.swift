import SwiftUI

struct SettingsView: View {
    @Binding var autoImportEnabled: Bool
    @Binding var syncOnAppOpenEnabled: Bool
    @Binding var backgroundSyncEnabled: Bool
    @Binding var smartSearchEnabled: Bool
    @Binding var saveSearchHistoryEnabled: Bool

    let lastSyncSummary: String?
    let syncProgressText: String?
    let isSyncing: Bool
    let isSyncPaused: Bool
    let storageUsedText: String
    let cacheSizeText: String
    let searchHistoryCount: Int
    let runSyncNow: () -> Void
    let pauseSync: () -> Void
    let resumeSync: () -> Void
    let clearCache: () -> Void
    let clearSearchHistory: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Import") {
                    Toggle("Auto-import screenshots", isOn: $autoImportEnabled)
                    Toggle("Sync on app open", isOn: $syncOnAppOpenEnabled)
                    Toggle("Background sync", isOn: $backgroundSyncEnabled)
                    Button("Sync now", action: runSyncNow)
                    if isSyncing {
                        Button(isSyncPaused ? "Resume import" : "Pause import") {
                            isSyncPaused ? resumeSync() : pauseSync()
                        }
                    }
                }

                Section("Storage") {
                    HStack {
                        Text("Storage Used")
                        Spacer()
                        Text(storageUsedText)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        clearCache()
                    } label: {
                        HStack {
                            Text("Clear Cache")
                            Spacer()
                            Text(cacheSizeText)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Search") {
                    Toggle("Semantic search", isOn: $smartSearchEnabled)
                    Toggle("Save Search History", isOn: $saveSearchHistoryEnabled)
                    Button {
                        clearSearchHistory()
                    } label: {
                        HStack {
                            Text("Clear Search History")
                            Spacer()
                            Text("\(searchHistoryCount)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(searchHistoryCount == 0)
                    Text("Semantic search uses Apple NLP embeddings for better matches.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Status") {
                    if let syncProgressText {
                        Text(syncProgressText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(lastSyncSummary ?? "No sync activity yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About / Info") {
                    Text("Deleting a screenshot from this app does not remove it from your Photos library.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
