import SwiftUI
import SwiftData

@main
struct ScreenshotsApp: App {
    init() {
        CLIPTokenizerBootstrap.registerDefaultTokenizerIfAvailable()
    }

    private let container: ModelContainer = {
        let schema = Schema([ScreenshotItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            ScreenshotsApp.resetCorruptedStoreFiles()
            do {
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                fatalError("Failed to initialize SwiftData container after reset: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }

    private static func resetCorruptedStoreFiles() {
        let fileManager = FileManager.default
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let storeURL = appSupportURL.appendingPathComponent("default.store")
        let urls = [
            storeURL,
            storeURL.appendingPathExtension("shm"),
            storeURL.appendingPathExtension("wal")
        ]

        for url in urls where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }
}
