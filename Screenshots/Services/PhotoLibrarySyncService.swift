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
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

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

        for (index, asset) in assetList.enumerated() {
            if isPaused {
                lastSummary = "Import paused at \(imported)/\(total)."
                break
            }

            if knownIds.contains(asset.localIdentifier) {
                skipped += 1
                if index % 10 == 0 {
                    syncProgressText = "Scanning \(index + 1)/\(total)"
                }
                continue
            }

            guard let image = await loadImage(for: asset) else {
                failed += 1
                continue
            }

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

            guard let filename = FileStore.saveImage(image) else {
                failed += 1
                continue
            }

            let title = asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Screenshot"
            let item = ScreenshotItem(
                title: title,
                date: asset.creationDate ?? .now,
                imagePath: filename,
                collectionTags: normalizedCollections.isEmpty ? ["Quick Notes"] : normalizedCollections,
                topicTags: normalizedTopics,
                mlLabels: classification.labels,
                extractedText: classification.extractedText,
                summaryText: "",
                sourceAssetId: asset.localIdentifier
            )

            context.insert(item)
            knownIds.insert(asset.localIdentifier)
            imported += 1
            syncProgressText = "Importing \(index + 1)/\(total)"

            // FIFO visual fill with periodic saves to keep UI responsive.
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
            let defaults = UserDefaults.standard
            let pending = defaults.integer(forKey: "ml.rebuild.pendingCount")
            defaults.set(pending + imported, forKey: "ml.rebuild.pendingCount")
        }
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

    private func loadImage(for asset: PHAsset) async -> UIImage? {
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
