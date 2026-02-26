import Foundation
import OSLog
import UIKit

actor CLIPEmbeddingService {
    static let shared = CLIPEmbeddingService()

    private let configuration = CLIPRuntimeConfiguration.default
    private var runtime: CLIPModelRuntime?
    private var initializationFailed = false
    private var textCache: [String: [Float]] = [:]
    private var cacheOrder: [String] = []
    private let maxTextCacheEntries = 64
    private var hasLoggedTokenizerRequirement = false

    func imageEmbeddingData(for image: UIImage) async -> Data? {
        guard let vector = await imageEmbedding(for: image) else { return nil }
        return EmbeddingCodec.encodeNormalizedVector(vector)
    }

    func imageEmbedding(for image: UIImage) async -> [Float]? {
        do {
            let runtime = try loadRuntimeIfNeeded()
            return try runtime.imageEmbedding(for: image)
        } catch {
            log(error, context: "imageEmbedding")
            return nil
        }
    }

    func textEmbedding(for query: String) async -> [Float]? {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return nil }

        if let cached = textCache[normalizedQuery] {
            return cached
        }

        do {
            let runtime = try loadRuntimeIfNeeded()
            let vector = try await runtime.textEmbedding(for: normalizedQuery)
            cacheTextVector(vector, for: normalizedQuery)
            return vector
        } catch {
            if case CLIPError.tokenizerRequired = error, hasLoggedTokenizerRequirement {
                return nil
            }
            if case CLIPError.tokenizerRequired = error {
                hasLoggedTokenizerRequirement = true
            }
            log(error, context: "textEmbedding")
            return nil
        }
    }

    private func cacheTextVector(_ vector: [Float], for query: String) {
        textCache[query] = vector
        cacheOrder.removeAll { $0 == query }
        cacheOrder.append(query)
        if cacheOrder.count > maxTextCacheEntries, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            textCache.removeValue(forKey: oldest)
        }
    }

    private func loadRuntimeIfNeeded() throws -> CLIPModelRuntime {
        if let runtime { return runtime }
        if initializationFailed {
            throw CLIPError.invalidModelContract(stage: "runtime", reason: "CLIP runtime initialization previously failed")
        }

        do {
            let loaded = try CLIPModelRuntime(bundle: .main, configuration: configuration)
            runtime = loaded
            CLIPLog.embeddingService.info("CLIP runtime initialized (ANE preferred)")
            return loaded
        } catch {
            initializationFailed = true
            throw error
        }
    }

    private func log(_ error: Error, context: String) {
        if let clipError = error as? CLIPError {
            CLIPLog.embeddingService.error("\(context, privacy: .public) failed: \(clipError.description, privacy: .public)")
        } else {
            CLIPLog.embeddingService.error("\(context, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}
