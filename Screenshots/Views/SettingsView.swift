import SwiftUI

struct SettingsView: View {
    @Binding var autoImportEnabled: Bool
    @Binding var smartSearchEnabled: Bool

    let lastSyncSummary: String?
    let syncProgressText: String?
    let isSyncing: Bool
    let isSyncPaused: Bool
    let rebuildRecommendation: String?
    let runSyncNow: () -> Void
    let pauseSync: () -> Void
    let resumeSync: () -> Void
    let rebuildCategories: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Import") {
                    Toggle("Auto-import screenshots", isOn: $autoImportEnabled)
                    Button("Sync now", action: runSyncNow)
                    if isSyncing {
                        Button(isSyncPaused ? "Resume import" : "Pause import") {
                            isSyncPaused ? resumeSync() : pauseSync()
                        }
                    }
                }

                Section("Search") {
                    Toggle("Semantic search", isOn: $smartSearchEnabled)
                    Text("Semantic search uses Apple NLP embeddings for better matches.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("ML Grouping") {
                    if let rebuildRecommendation {
                        Text(rebuildRecommendation)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Collections and groups update automatically during import. Rebuild only when recommendations appear.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button(rebuildRecommendation == nil ? "Rebuild categories" : "Rebuild categories (Recommended)", action: rebuildCategories)

                    Text("Apple Intelligence calls are budgeted per day; local Vision/NLP fallback keeps import efficient when budget is reached.")
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
            }
            .navigationTitle("Settings")
        }
    }
}
