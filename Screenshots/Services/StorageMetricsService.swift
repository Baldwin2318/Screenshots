import Foundation

enum StorageMetricsService {
    private static let cacheDirectoryName = "ScreenshotsCache"

    static func appStorageUsageBytes() -> Int64 {
        directorySize(at: FileStore.documentsURL)
    }

    static func cacheUsageBytes() -> Int64 {
        directorySize(at: cacheDirectoryURL())
    }

    static func clearCache() {
        let fileManager = FileManager.default
        let cacheURL = cacheDirectoryURL()

        guard let entries = try? fileManager.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: nil) else {
            return
        }

        for entry in entries {
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func cacheDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(cacheDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            guard values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
