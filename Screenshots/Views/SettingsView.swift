import SwiftUI

struct SettingsView: View {
    @Binding var autoImportEnabled: Bool
    @Binding var smartSearchEnabled: Bool

    let lastSyncSummary: String?
    let syncProgressText: String?
    let isSyncing: Bool
    let isSyncPaused: Bool
    let runSyncNow: () -> Void
    let pauseSync: () -> Void
    let resumeSync: () -> Void

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
