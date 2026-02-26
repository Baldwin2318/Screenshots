import Accelerate
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import UIKit

struct SearchIndexSnapshot: Sendable {
    let id: UUID
    let sortDate: TimeInterval
    let title: String
    let extractedText: String
    let summaryText: String
    let labels: [String]
    let imageEmbedding: Data?
}

actor SearchIndexService {
    private struct IndexedDocument: Sendable {
        let id: UUID
        let sortDate: TimeInterval
        let searchableText: String
        let tokens: [String]
        let imageEmbedding: [Float]?
    }

    private var documents: [UUID: IndexedDocument] = [:]
    private var orderedIds: [UUID] = []
    private var cachedResults: [String: [UUID]] = [:]
    private var cacheOrder: [String] = []
    private var lastFingerprint = 0
    private let maxCacheEntries = 120
    private let semanticAcceptanceThreshold: Float = 0.14

    func reindexIfNeeded(with snapshots: [SearchIndexSnapshot]) {
        let fingerprint = Self.fingerprint(for: snapshots)
        guard fingerprint != lastFingerprint else { return }

        let sorted = snapshots.sorted { $0.sortDate > $1.sortDate }
        var newDocuments: [UUID: IndexedDocument] = [:]
        newDocuments.reserveCapacity(sorted.count)

        for snapshot in sorted {
            let searchableText = Self.normalize([
                snapshot.title,
                snapshot.extractedText,
                snapshot.summaryText,
                snapshot.labels.joined(separator: " ")
            ].joined(separator: " "))

            let rawTokens = Self.tokens(from: searchableText)
            let compactTokens = Array(Set(rawTokens)).prefix(80)
            let decodedEmbedding = snapshot.imageEmbedding.flatMap(EmbeddingCodec.decodeNormalizedVector(from:))

            newDocuments[snapshot.id] = IndexedDocument(
                id: snapshot.id,
                sortDate: snapshot.sortDate,
                searchableText: searchableText,
                tokens: Array(compactTokens),
                imageEmbedding: decodedEmbedding
            )
        }

        documents = newDocuments
        orderedIds = sorted.map(\.id)
        lastFingerprint = fingerprint
        cachedResults.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    func search(query rawQuery: String) async -> [UUID] {
        let query = Self.normalize(rawQuery)
        if query.isEmpty { return orderedIds }

        if let cached = cachedResults[query] {
            return cached
        }

        let lexicalIds = lexicalSearch(query: query)
        let semanticIds = await semanticSearch(query: query) ?? []
        let merged = Self.mergeResults(semanticIds: semanticIds, lexicalIds: lexicalIds)
        let final = merged.isEmpty ? lexicalIds : merged

        setCache(final, for: query)
        return final
    }

    private func lexicalSearch(query: String) -> [UUID] {
        let queryTokens = Self.tokens(from: query)
        guard !queryTokens.isEmpty else { return orderedIds }

        var scored: [(id: UUID, score: Int, date: TimeInterval)] = []
        scored.reserveCapacity(documents.count)

        for id in orderedIds {
            guard let document = documents[id] else { continue }
            let score = Self.score(document: document, query: query, queryTokens: queryTokens)
            if score > 0 {
                scored.append((id: document.id, score: score, date: document.sortDate))
            }
        }

        scored.sort {
            if $0.score == $1.score {
                return $0.date > $1.date
            }
            return $0.score > $1.score
        }

        return scored.map(\.id)
    }

    private func semanticSearch(query: String) async -> [UUID]? {
        let textVector = await CLIPEmbeddingService.shared.textEmbedding(for: query)
        guard let textVector, !textVector.isEmpty else { return nil }

        var scored: [(id: UUID, score: Float, date: TimeInterval)] = []
        scored.reserveCapacity(documents.count)

        for id in orderedIds {
            guard let document = documents[id], let imageVector = document.imageEmbedding else { continue }
            let score = Self.cosineSimilarity(lhs: textVector, rhs: imageVector)
            if score >= semanticAcceptanceThreshold {
                scored.append((id: id, score: score, date: document.sortDate))
            }
        }

        guard !scored.isEmpty else { return nil }

        scored.sort {
            if abs($0.score - $1.score) < 0.0001 {
                return $0.date > $1.date
            }
            return $0.score > $1.score
        }

        return scored.map(\.id)
    }

    private func setCache(_ ids: [UUID], for query: String) {
        cachedResults[query] = ids
        cacheOrder.removeAll { $0 == query }
        cacheOrder.append(query)

        if cacheOrder.count > maxCacheEntries, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cachedResults.removeValue(forKey: oldest)
        }
    }

    private static func mergeResults(semanticIds: [UUID], lexicalIds: [UUID]) -> [UUID] {
        guard !semanticIds.isEmpty else { return lexicalIds }
        guard !lexicalIds.isEmpty else { return semanticIds }

        var merged: [UUID] = []
        merged.reserveCapacity(max(semanticIds.count, lexicalIds.count))
        var seen = Set<UUID>()
        seen.reserveCapacity(semanticIds.count + lexicalIds.count)

        for id in semanticIds where seen.insert(id).inserted {
            merged.append(id)
        }

        for id in lexicalIds where seen.insert(id).inserted {
            merged.append(id)
        }

        return merged
    }

    private static func cosineSimilarity(lhs: [Float], rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var dot: Float = 0
        lhs.withUnsafeBufferPointer { lp in
            rhs.withUnsafeBufferPointer { rp in
                vDSP_dotpr(lp.baseAddress!, 1, rp.baseAddress!, 1, &dot, vDSP_Length(lhs.count))
            }
        }
        return dot
    }

    private static func score(document: IndexedDocument, query: String, queryTokens: [String]) -> Int {
        var score = 0

        if document.searchableText.contains(query) {
            score += 85
        }

        for queryToken in queryTokens {
            if document.tokens.contains(queryToken) {
                score += 24
                continue
            }

            let hasPrefix = document.tokens.contains { token in
                token.hasPrefix(queryToken) || queryToken.hasPrefix(token)
            }
            if hasPrefix {
                score += 14
                continue
            }

            if queryToken.count >= 4 {
                let hasFuzzy = document.tokens.contains { token in
                    let delta = abs(token.count - queryToken.count)
                    guard delta <= 1 else { return false }
                    return boundedLevenshtein(token, queryToken, maxDistance: 1) <= 1
                }
                if hasFuzzy {
                    score += 10
                }
            }
        }

        return score
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(from value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func fingerprint(for snapshots: [SearchIndexSnapshot]) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshots.count)

        for snapshot in snapshots {
            hasher.combine(snapshot.id)
            hasher.combine(Int(snapshot.sortDate))
            hasher.combine(snapshot.title)
            hasher.combine(snapshot.extractedText.prefix(64))
            hasher.combine(snapshot.summaryText.prefix(64))
            hasher.combine(snapshot.labels.joined(separator: "|"))
            if let embedding = snapshot.imageEmbedding {
                hasher.combine(embedding.count)
                hasher.combine(embedding.prefix(64))
            } else {
                hasher.combine(0)
            }
        }

        return hasher.finalize()
    }

    private static func boundedLevenshtein(_ lhs: String, _ rhs: String, maxDistance: Int) -> Int {
        if lhs == rhs { return 0 }

        let left = Array(lhs)
        let right = Array(rhs)

        if abs(left.count - right.count) > maxDistance {
            return maxDistance + 1
        }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for i in 1...left.count {
            current[0] = i
            var rowMin = current[0]

            for j in 1...right.count {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                let insertion = current[j - 1] + 1
                let deletion = previous[j] + 1

                let best = min(substitution, insertion, deletion)
                current[j] = best
                rowMin = min(rowMin, best)
            }

            if rowMin > maxDistance {
                return maxDistance + 1
            }

            swap(&previous, &current)
        }

        return previous[right.count]
    }
}

enum EmbeddingCodec {
    static let dimension = 512

    static func encodeNormalizedVector(_ vector: [Float]) -> Data? {
        guard vector.count == dimension else { return nil }
        let normalized = normalize(vector)
        guard normalized.count == dimension else { return nil }
        return normalized.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: dimension * MemoryLayout<Float>.size)
        }
    }

    static func decodeNormalizedVector(from data: Data) -> [Float]? {
        let expectedByteCount = dimension * MemoryLayout<Float>.size
        guard data.count == expectedByteCount else { return nil }
        let floatCount = dimension

        var vector = [Float](repeating: 0, count: floatCount)
        _ = vector.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        return normalize(vector)
    }

    static func normalize(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return [] }
        var squares: Float = 0
        vector.withUnsafeBufferPointer { pointer in
            vDSP_svesq(pointer.baseAddress!, 1, &squares, vDSP_Length(vector.count))
        }
        let magnitude = sqrt(max(squares, 0.000_000_1))
        var divisor = magnitude
        var output = [Float](repeating: 0, count: vector.count)
        vector.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                vDSP_vsdiv(src.baseAddress!, 1, &divisor, dst.baseAddress!, 1, vDSP_Length(vector.count))
            }
        }
        return output
    }
}

struct CLIPTokenizedText: Sendable {
    let inputIDs: [Int32]
    let attentionMask: [Int32]
    let maxLength: Int
}

protocol CLIPTextTokenizing: Sendable {
    func encode(_ text: String, maxLength: Int) -> CLIPTokenizedText?
}

actor CLIPTextTokenizerRegistry {
    static let shared = CLIPTextTokenizerRegistry()

    private var tokenizer: CLIPTextTokenizing?

    func setTokenizer(_ tokenizer: CLIPTextTokenizing) {
        self.tokenizer = tokenizer
    }

    func encode(_ text: String, maxLength: Int) -> CLIPTokenizedText? {
        tokenizer?.encode(text, maxLength: maxLength)
    }
}

actor CLIPEmbeddingService {
    static let shared = CLIPEmbeddingService()

    private var runtime: CLIPModelRuntime?
    private var failedToInitialize = false
    private var textCache: [String: [Float]] = [:]
    private var cacheOrder: [String] = []
    private let maxCacheEntries = 64

    func imageEmbeddingData(for image: UIImage) async -> Data? {
        guard let vector = await imageEmbedding(for: image) else { return nil }
        return EmbeddingCodec.encodeNormalizedVector(vector)
    }

    func imageEmbedding(for image: UIImage) async -> [Float]? {
        guard let runtime = loadRuntimeIfNeeded() else { return nil }
        return runtime.imageEmbedding(for: image)
    }

    func textEmbedding(for query: String) async -> [Float]? {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return nil }

        if let cached = textCache[normalizedQuery] {
            return cached
        }

        guard let runtime = loadRuntimeIfNeeded() else { return nil }
        guard let vector = await runtime.textEmbedding(for: normalizedQuery) else { return nil }

        textCache[normalizedQuery] = vector
        cacheOrder.removeAll { $0 == normalizedQuery }
        cacheOrder.append(normalizedQuery)
        if cacheOrder.count > maxCacheEntries, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            textCache.removeValue(forKey: oldest)
        }
        return vector
    }

    private func loadRuntimeIfNeeded() -> CLIPModelRuntime? {
        if let runtime { return runtime }
        if failedToInitialize { return nil }
        let loaded = CLIPModelRuntime(bundle: .main)
        if loaded.isReady {
            runtime = loaded
            return loaded
        }
        failedToInitialize = true
        return nil
    }
}

private final class CLIPModelRuntime {
    private let imageModel: MLModel?
    private let textModel: MLModel?

    var isReady: Bool {
        imageModel != nil && textModel != nil
    }

    init(bundle: Bundle) {
        self.imageModel = Self.loadModel(named: "ImageEncoder", in: bundle)
        self.textModel = Self.loadModel(named: "TextEncoder", in: bundle)
    }

    func imageEmbedding(for image: UIImage) -> [Float]? {
        guard let imageModel else { return nil }
        guard let inputName = Self.imageInputName(in: imageModel) else { return nil }
        let targetSize = Self.imageInputSize(in: imageModel) ?? CGSize(width: 224, height: 224)
        guard let pixelBuffer = Self.makePixelBuffer(from: image, size: targetSize) else { return nil }

        let provider = try? MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(pixelBuffer: pixelBuffer)
        ])
        guard let provider else { return nil }
        guard let output = try? imageModel.prediction(from: provider) else { return nil }
        guard let vector = Self.extractEmbedding(from: output) else { return nil }
        return EmbeddingCodec.normalize(vector)
    }

    func textEmbedding(for query: String) async -> [Float]? {
        guard let textModel else { return nil }

        if let stringInputName = Self.stringInputName(in: textModel) {
            let provider = try? MLDictionaryFeatureProvider(dictionary: [
                stringInputName: MLFeatureValue(string: query)
            ])
            guard let provider, let output = try? await textModel.prediction(from: provider), let vector = Self.extractEmbedding(from: output) else {
                return nil
            }
            return EmbeddingCodec.normalize(vector)
        }

        let tokenLength = Self.textSequenceLength(in: textModel) ?? 77
        guard let tokenized = await CLIPTextTokenizerRegistry.shared.encode(query, maxLength: tokenLength) else {
            return nil
        }

        let names = Self.tokenInputNames(in: textModel)
        guard let idsName = names.ids, let maskName = names.mask else { return nil }
        guard let idsArray = Self.makeInt32MultiArray(tokenized.inputIDs),
              let maskArray = Self.makeInt32MultiArray(tokenized.attentionMask) else {
            return nil
        }

        var features: [String: MLFeatureValue] = [
            idsName: MLFeatureValue(multiArray: idsArray),
            maskName: MLFeatureValue(multiArray: maskArray)
        ]

        if let tokenTypeName = names.tokenType,
           let tokenTypeArray = Self.makeInt32MultiArray([Int32](repeating: 0, count: tokenized.maxLength)) {
            features[tokenTypeName] = MLFeatureValue(multiArray: tokenTypeArray)
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: features),
              let output = try? await textModel.prediction(from: provider),
              let vector = Self.extractEmbedding(from: output) else {
            return nil
        }

        return EmbeddingCodec.normalize(vector)
    }

    private static func loadModel(named name: String, in bundle: Bundle) -> MLModel? {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine

        guard let modelURL = bundle.url(forResource: name, withExtension: "mlmodelc") else {
            return nil
        }

        return try? MLModel(contentsOf: modelURL, configuration: configuration)
    }

    private static func imageInputName(in model: MLModel) -> String? {
        model.modelDescription.inputDescriptionsByName.first { _, description in
            description.imageConstraint != nil
        }?.key
    }

    private static func imageInputSize(in model: MLModel) -> CGSize? {
        guard let name = imageInputName(in: model),
              let constraint = model.modelDescription.inputDescriptionsByName[name]?.imageConstraint else {
            return nil
        }
        return CGSize(width: constraint.pixelsWide, height: constraint.pixelsHigh)
    }

    private static func stringInputName(in model: MLModel) -> String? {
        model.modelDescription.inputDescriptionsByName.first { _, description in
            description.type == .string
        }?.key
    }

    private static func textSequenceLength(in model: MLModel) -> Int? {
        for (_, description) in model.modelDescription.inputDescriptionsByName {
            guard description.type == .multiArray,
                  let constraint = description.multiArrayConstraint else { continue }
            let shape = constraint.shape.map { $0.intValue }
            if let last = shape.last, last > 0 {
                return last
            }
        }
        return nil
    }

    private static func tokenInputNames(in model: MLModel) -> (ids: String?, mask: String?, tokenType: String?) {
        var ids: String?
        var mask: String?
        var tokenType: String?

        for (name, description) in model.modelDescription.inputDescriptionsByName {
            guard description.type == .multiArray else { continue }
            let lower = name.lowercased()
            if ids == nil, lower.contains("input") && lower.contains("id") {
                ids = name
            } else if mask == nil, lower.contains("mask") {
                mask = name
            } else if tokenType == nil, (lower.contains("token") && lower.contains("type")) || lower.contains("segment") {
                tokenType = name
            }
        }

        if ids == nil {
            ids = model.modelDescription.inputDescriptionsByName.keys.first(where: { $0.lowercased().contains("id") })
        }
        if mask == nil {
            mask = model.modelDescription.inputDescriptionsByName.keys.first(where: { $0.lowercased().contains("mask") })
        }

        return (ids, mask, tokenType)
    }

    private static func extractEmbedding(from provider: MLFeatureProvider) -> [Float]? {
        let outputs = provider.featureNames.compactMap { name -> MLFeatureValue? in
            provider.featureValue(for: name)
        }

        if let array = outputs.first(where: { $0.type == .multiArray })?.multiArrayValue {
            return collapseEmbedding(Self.floatArray(from: array))
        }

        return nil
    }

    private static func collapseEmbedding(_ values: [Float]) -> [Float]? {
        guard !values.isEmpty else { return nil }
        if values.count == EmbeddingCodec.dimension {
            return values
        }
        if values.count > EmbeddingCodec.dimension, values.count % EmbeddingCodec.dimension == 0 {
            let rows = values.count / EmbeddingCodec.dimension
            var pooled = [Float](repeating: 0, count: EmbeddingCodec.dimension)
            for row in 0..<rows {
                let base = row * EmbeddingCodec.dimension
                for col in 0..<EmbeddingCodec.dimension {
                    pooled[col] += values[base + col]
                }
            }
            var divisor = Float(rows)
            pooled.withUnsafeMutableBufferPointer { buffer in
                vDSP_vsdiv(buffer.baseAddress!, 1, &divisor, buffer.baseAddress!, 1, vDSP_Length(EmbeddingCodec.dimension))
            }
            return pooled
        }
        if values.count >= EmbeddingCodec.dimension {
            return Array(values.prefix(EmbeddingCodec.dimension))
        }
        return nil
    }

    private static func floatArray(from multiArray: MLMultiArray) -> [Float] {
        let count = multiArray.count
        var result = [Float](repeating: 0, count: count)

        switch multiArray.dataType {
        case .float32:
            let pointer = multiArray.dataPointer.bindMemory(to: Float32.self, capacity: count)
            for idx in 0..<count { result[idx] = pointer[idx] }
        case .double:
            let pointer = multiArray.dataPointer.bindMemory(to: Double.self, capacity: count)
            for idx in 0..<count { result[idx] = Float(pointer[idx]) }
        case .float16:
            let pointer = multiArray.dataPointer.bindMemory(to: UInt16.self, capacity: count)
            for idx in 0..<count {
                result[idx] = Self.float32FromFloat16(pointer[idx])
            }
        case .int32:
            let pointer = multiArray.dataPointer.bindMemory(to: Int32.self, capacity: count)
            for idx in 0..<count { result[idx] = Float(pointer[idx]) }
        default:
            return []
        }

        return result
    }

    private static func makeInt32MultiArray(_ values: [Int32]) -> MLMultiArray? {
        guard !values.isEmpty else { return nil }
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32) else {
            return nil
        }
        let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        for index in 0..<values.count {
            pointer[index] = values[index]
        }
        return array
    }

    private static func makePixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }

        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        return pixelBuffer
    }

    private static func float32FromFloat16(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        var exponent = UInt32(bits & 0x7C00) >> 10
        var fraction = UInt32(bits & 0x03FF)

        if exponent == 0 {
            if fraction == 0 {
                return Float(bitPattern: sign)
            }
            exponent = 1
            while (fraction & 0x0400) == 0 {
                fraction <<= 1
                exponent -= 1
            }
            fraction &= 0x03FF
        } else if exponent == 31 {
            let pattern = sign | 0x7F80_0000 | (fraction << 13)
            return Float(bitPattern: pattern)
        }

        let exp32 = (exponent + (127 - 15)) << 23
        let frac32 = fraction << 13
        return Float(bitPattern: sign | exp32 | frac32)
    }
}
