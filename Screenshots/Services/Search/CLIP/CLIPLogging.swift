import Foundation
import OSLog

enum CLIPLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Screenshots"

    nonisolated(unsafe) static let runtime = Logger(subsystem: subsystem, category: "CLIPRuntime")
    nonisolated(unsafe) static let embeddingService = Logger(subsystem: subsystem, category: "CLIPEmbeddingService")
    nonisolated(unsafe) static let tokenizer = Logger(subsystem: subsystem, category: "CLIPTokenizer")
}

enum CLIPError: Error, Sendable, CustomStringConvertible {
    case missingCompiledModel(name: String)
    case modelLoadFailed(name: String, message: String)
    case invalidModelContract(stage: String, reason: String)
    case tokenizerRequired(sequenceLength: Int)
    case predictionFailed(stage: String, message: String)
    case featureProviderCreationFailed(stage: String)
    case outputMissing(stage: String, outputName: String)
    case embeddingExtractionFailed(stage: String, reason: String)
    case imagePreprocessingFailed(reason: String)

    var description: String {
        switch self {
        case .missingCompiledModel(let name):
            return "Missing compiled CoreML model \(name).mlmodelc in app bundle"
        case .modelLoadFailed(let name, let message):
            return "Failed to load model \(name): \(message)"
        case .invalidModelContract(let stage, let reason):
            return "Invalid CLIP model contract [\(stage)]: \(reason)"
        case .tokenizerRequired(let sequenceLength):
            return "Tokenizer required for tokenized text encoder (sequence length \(sequenceLength))"
        case .predictionFailed(let stage, let message):
            return "Prediction failed [\(stage)]: \(message)"
        case .featureProviderCreationFailed(let stage):
            return "Failed to create MLFeatureProvider for \(stage)"
        case .outputMissing(let stage, let outputName):
            return "Expected output '\(outputName)' missing for \(stage)"
        case .embeddingExtractionFailed(let stage, let reason):
            return "Embedding extraction failed [\(stage)]: \(reason)"
        case .imagePreprocessingFailed(let reason):
            return "Image preprocessing failed: \(reason)"
        }
    }
}
