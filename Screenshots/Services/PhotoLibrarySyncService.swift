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

    private struct ImportedPayload {
        let title: String
        let date: Date
        let imagePath: String
        let labels: [String]
        let extractedText: String
        let sourceAssetId: String
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

    func syncIfNeeded(context: ModelContext, existingItems: [ScreenshotItem], autoImportEnabled: Bool) async {
        guard autoImportEnabled else { return }
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

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let defaults = UserDefaults.standard

        if existingItems.isEmpty {
            defaults.removeObject(forKey: lastSyncCursorKey)
        }

        let lastSyncDate = defaults.object(forKey: lastSyncCursorKey) as? Date
        if let lastSyncDate {
            options.predicate = NSPredicate(format: "creationDate > %@", lastSyncDate as NSDate)
        }

        let assets = PHAsset.fetchAssets(in: screenshotsAlbum, options: options)
        var assetList: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in
            assetList.append(asset)
        }

        var knownIds = Set(existingItems.compactMap(\.sourceAssetId))
        var imported = 0
        var skipped = 0
        var failed = 0
        let total = assetList.count
        var newestImportedDate: Date?

        for (index, asset) in assetList.enumerated() {
            if isPaused {
                lastSummary = "Import paused at \(imported)/\(total)."
                break
            }

            if knownIds.contains(asset.localIdentifier) {
                skipped += 1
                if index % 20 == 0 {
                    syncProgressText = "Scanning \(index + 1)/\(total)"
                }
                continue
            }

            syncProgressText = "Importing \(index + 1)/\(total)"

            guard let payload = await processAsset(asset) else {
                failed += 1
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
                sourceAssetId: payload.sourceAssetId
            )

            context.insert(item)
            knownIds.insert(payload.sourceAssetId)
            imported += 1
            if let currentNewest = newestImportedDate {
                if payload.date > currentNewest {
                    newestImportedDate = payload.date
                }
            } else {
                newestImportedDate = payload.date
            }

            if imported % 8 == 0 {
                try? context.save()
                lastSummary = "Importing \(imported) screenshots..."
                await Task.yield()
            }
        }

        if imported > 0 {
            try? context.save()
        }

        if imported > 0 || skipped > 0 || failed > 0 {
            lastSummary = "Imported \(imported), skipped \(skipped), failed \(failed)."
        } else {
            lastSummary = "Up to date."
        }

        if let newestImportedDate {
            defaults.set(newestImportedDate, forKey: lastSyncCursorKey)
        } else if let lastAssetDate = assetList.compactMap(\.creationDate).max() {
            defaults.set(lastAssetDate, forKey: lastSyncCursorKey)
        }
    }

    private func processAsset(_ asset: PHAsset) async -> ImportedPayload? {
        await Task.detached(priority: .userInitiated) {
            guard let image = await Self.loadImage(for: asset) else {
                return nil
            }

            let classification = await ScreenshotClassifier.classify(image: image)

            guard let filename = FileStore.saveImage(image) else {
                return nil
            }

            let date = asset.creationDate ?? .now
            let title = date.formatted(date: .abbreviated, time: .shortened)

            return ImportedPayload(
                title: title,
                date: date,
                imagePath: filename,
                labels: classification.labels,
                extractedText: classification.extractedText,
                sourceAssetId: asset.localIdentifier
            )
        }.value
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
