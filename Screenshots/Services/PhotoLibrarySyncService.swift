import Combine
import Foundation
import Photos
import UIKit
import SwiftData

@MainActor
final class PhotoLibrarySyncService: NSObject, ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var isPaused = false
    @Published private(set) var syncProgressText: String?
    @Published private(set) var lastSummary: String?

    private var isRegistered = false
    private var onLibraryChanged: (() -> Void)?
    private let lastSyncCursorKey = "sync.lastCreationDate.v1"
    private struct ImportTuning {
        let batchSize: Int
        let batchDelayNanoseconds: UInt64

        static func current() -> ImportTuning {
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                return ImportTuning(batchSize: 10, batchDelayNanoseconds: 900_000_000)
            }
            return ImportTuning(batchSize: 30, batchDelayNanoseconds: 280_000_000)
        }
    }

    private struct ImportedPayload {
        let title: String
        let date: Date
        let imagePath: String
        let labels: [String]
        let extractedText: String
        let sourceAssetId: String
        let clipEmbedding: Data?
    }

    func startObserving(onLibraryChanged: @escaping () -> Void) {
        self.onLibraryChanged = onLibraryChanged
        guard !isRegistered else { return }
        PHPhotoLibrary.shared().register(self)
        isRegistered = true
    }

    func stopObserving() {
        guard isRegistered else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        isRegistered = false
    }

    func pauseSync() {
        isPaused = true
        lastSummary = "Import paused."
    }

    func resumeSync() {
        isPaused = false
        lastSummary = "Import resumed."
        onLibraryChanged?()
    }

    func syncIfNeeded(context: ModelContext, existingItems: [ScreenshotItem], allowImport: Bool) async {
        guard !isSyncing else { return }

        isSyncing = true
        defer {
            isSyncing = false
            syncProgressText = nil
        }

        let authorized = await requestAccessIfNeeded()
        guard authorized else {
            lastSummary = "Photo access is required."
            return
        }

        let albums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumScreenshots,
            options: nil
        )

        guard let screenshotsAlbum = albums.firstObject else {
            lastSummary = "Screenshots album not found."
            return
        }

        let defaults = UserDefaults.standard
        let allAssetsOptions = PHFetchOptions()
        allAssetsOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        if existingItems.filter({ $0.sourceAssetId != nil }).isEmpty {
            defaults.removeObject(forKey: lastSyncCursorKey)
        }

        let allAssets = PHAsset.fetchAssets(in: screenshotsAlbum, options: allAssetsOptions)
        var currentAssetIds = Set<String>()
        currentAssetIds.reserveCapacity(allAssets.count)
        var newestAssetDate: Date?
        allAssets.enumerateObjects { asset, index, _ in
            currentAssetIds.insert(asset.localIdentifier)
            if index == 0 {
                newestAssetDate = asset.creationDate
            }
        }

        var deleted = 0
        var deletedSourceIds = Set<String>()
        for item in existingItems {
            guard let sourceAssetId = item.sourceAssetId else { continue }
            guard !currentAssetIds.contains(sourceAssetId) else { continue }

            FileStore.deleteImage(filename: item.imagePath)
            context.delete(item)
            deleted += 1
            deletedSourceIds.insert(sourceAssetId)
        }

        if deleted > 0 {
            try? context.save()
        }

        guard allowImport else {
            if let newestAssetDate {
                defaults.set(newestAssetDate, forKey: lastSyncCursorKey)
            }
            lastSummary = deleted > 0
                ? "Removed \(deleted) deleted screenshots from Photos."
                : "Up to date."
            return
        }

        let options = PHFetchOptions()
        // Ascending order keeps cursor checkpointing resumable if import pauses mid-run.
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let lastSyncDate = defaults.object(forKey: lastSyncCursorKey) as? Date
        if let lastSyncDate {
            options.predicate = NSPredicate(format: "creationDate > %@", lastSyncDate as NSDate)
        }

        let assets = PHAsset.fetchAssets(in: screenshotsAlbum, options: options)
        var assetList: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in
            assetList.append(asset)
        }

        let existingBySourceId = Dictionary(uniqueKeysWithValues: existingItems.compactMap { item in
            item.sourceAssetId.map { ($0, item) }
        })
        var knownIds = Set(existingItems.compactMap(\.sourceAssetId))
        knownIds.subtract(deletedSourceIds)
        var imported = 0
        var indexed = 0
        var skipped = 0
        var failed = 0
        let total = assetList.count
        var newestImportedDate: Date?
        var checkpointCursorDate = lastSyncDate
        var encounteredFailure = false
        var scannedInBatch = 0

        for (index, asset) in assetList.enumerated() {
            if isPaused {
                lastSummary = "Import paused at \(imported)/\(total)."
                break
            }
            if Task.isCancelled {
                lastSummary = "Import cancelled."
                break
            }

            let tuning = ImportTuning.current()
            let assetDate = asset.creationDate ?? .now

            if knownIds.contains(asset.localIdentifier) {
                if let existing = existingBySourceId[asset.localIdentifier],
                   existing.clipEmbedding == nil,
                   let embedding = await Self.computeEmbedding(for: asset) {
                    existing.clipEmbedding = embedding
                    indexed += 1
                }

                skipped += 1
                if !encounteredFailure {
                    checkpointCursorDate = Self.maxDate(checkpointCursorDate, assetDate)
                }
                if index % 20 == 0 {
                    syncProgressText = "Scanning \(index + 1)/\(total)"
                }
                scannedInBatch += 1
                if scannedInBatch >= tuning.batchSize {
                    try? context.save()
                    if let checkpointCursorDate {
                        defaults.set(checkpointCursorDate, forKey: lastSyncCursorKey)
                    }
                    scannedInBatch = 0
                    try? await Task.sleep(nanoseconds: tuning.batchDelayNanoseconds)
                }
                continue
            }

            syncProgressText = "Importing \(index + 1)/\(total)"

            guard let payload = await processAsset(asset) else {
                failed += 1
                encounteredFailure = true
                scannedInBatch += 1
                continue
            }

            let item = ScreenshotItem(
                title: payload.title,
                date: payload.date,
                imagePath: payload.imagePath,
                collectionTags: [],
                topicTags: [],
                mlLabels: payload.labels,
                extractedText: payload.extractedText,
                summaryText: "",
                sourceAssetId: payload.sourceAssetId,
                clipEmbedding: payload.clipEmbedding
            )

            context.insert(item)
            knownIds.insert(payload.sourceAssetId)
            imported += 1
            newestImportedDate = Self.maxDate(newestImportedDate, payload.date)
            if !encounteredFailure {
                checkpointCursorDate = Self.maxDate(checkpointCursorDate, payload.date)
            }
            scannedInBatch += 1

            if scannedInBatch >= tuning.batchSize {
                try? context.save()
                if let checkpointCursorDate {
                    defaults.set(checkpointCursorDate, forKey: lastSyncCursorKey)
                }
                lastSummary = ProcessInfo.processInfo.isLowPowerModeEnabled
                    ? "Low Power Mode: importing carefully (\(imported) imported)."
                    : "Importing \(imported) screenshots..."
                scannedInBatch = 0
                try? await Task.sleep(nanoseconds: tuning.batchDelayNanoseconds)
                await Task.yield()
            }
        }

        if imported > 0 || indexed > 0 {
            try? context.save()
        }

        if imported > 0 || indexed > 0 || skipped > 0 || failed > 0 || deleted > 0 {
            lastSummary = "Imported \(imported), indexed \(indexed), removed \(deleted), skipped \(skipped), failed \(failed)."
        } else {
            lastSummary = "Up to date."
        }

        if let checkpointCursorDate {
            defaults.set(checkpointCursorDate, forKey: lastSyncCursorKey)
        } else if !encounteredFailure, let newestImportedDate {
            defaults.set(newestImportedDate, forKey: lastSyncCursorKey)
        } else if !encounteredFailure, let newestAssetDate {
            defaults.set(newestAssetDate, forKey: lastSyncCursorKey)
        } else if !encounteredFailure, let lastAssetDate = assetList.compactMap(\.creationDate).max() {
            defaults.set(lastAssetDate, forKey: lastSyncCursorKey)
        }
    }

    private func processAsset(_ asset: PHAsset) async -> ImportedPayload? {
        await Task.detached(priority: .userInitiated) {
            guard var image: UIImage? = await Self.loadImage(for: asset) else {
                return nil
            }

            guard let loadedImage = image else { return nil }
            let classification = await ScreenshotClassifier.classify(image: loadedImage)
            let clipEmbedding = await CLIPEmbeddingService.shared.imageEmbeddingData(for: loadedImage)

            guard let filename = FileStore.saveImage(loadedImage) else {
                image = nil
                return nil
            }
            image = nil

            let date = asset.creationDate ?? .now
            let title = date.formatted(date: .abbreviated, time: .shortened)

            return ImportedPayload(
                title: title,
                date: date,
                imagePath: filename,
                labels: classification.labels,
                extractedText: classification.extractedText,
                sourceAssetId: asset.localIdentifier,
                clipEmbedding: clipEmbedding
            )
        }.value
    }

    private nonisolated static func computeEmbedding(for asset: PHAsset) async -> Data? {
        guard let image = await loadImage(for: asset) else { return nil }
        return await CLIPEmbeddingService.shared.imageEmbeddingData(for: image)
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return lhs > rhs ? lhs : rhs
    }

    private func requestAccessIfNeeded() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return result == .authorized || result == .limited
        default:
            return false
        }
    }

    private nonisolated static func loadImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true

            let target = CGSize(width: 1400, height: 2400)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false

                if cancelled {
                    continuation.resume(returning: nil)
                    return
                }
                if degraded { return }

                continuation.resume(returning: image)
            }
        }
    }
}

extension PhotoLibrarySyncService: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            onLibraryChanged?()
        }
    }
}
