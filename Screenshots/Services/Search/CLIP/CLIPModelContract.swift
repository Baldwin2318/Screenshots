import CoreGraphics
import CoreML
import Foundation
import OSLog

struct CLIPRuntimeConfiguration: Sendable {
    let imageModelName: String
    let textModelName: String
    let embeddingDimension: Int
    let poolingStrategy: CLIPEmbeddingPoolingStrategy

    static let `default` = CLIPRuntimeConfiguration(
        imageModelName: "ImageEncoder",
        textModelName: "TextEncoder",
        embeddingDimension: EmbeddingCodec.dimension,
        poolingStrategy: .meanRowsOrPrefix
    )
}

enum CLIPEmbeddingPoolingStrategy: Sendable {
    case exact
    case meanRowsOrPrefix
}

enum CLIPTextInputContract: Sendable {
    case string(inputName: String)
    case tokenized(inputIDsName: String, attentionMaskName: String, tokenTypeName: String?, sequenceLength: Int)
}

struct CLIPResolvedContract {
    let imageInputName: String
    let imageTargetSize: CGSize?
    let imageOutputName: String
    let textInput: CLIPTextInputContract
    let textOutputName: String
    let embeddingDimension: Int
    let poolingStrategy: CLIPEmbeddingPoolingStrategy
}

enum CLIPModelContractResolver {
    static func resolve(
        imageModel: MLModel,
        textModel: MLModel,
        configuration: CLIPRuntimeConfiguration
    ) throws -> CLIPResolvedContract {
        let imageInputName = try imageInputName(in: imageModel)
        let imageTargetSize = imageInputSize(in: imageModel, inputName: imageInputName)
        let imageOutputName = try outputName(in: imageModel, stage: "image")
        let textOutputName = try outputName(in: textModel, stage: "text")
        let textInput = try textInputContract(in: textModel)

        let contract = CLIPResolvedContract(
            imageInputName: imageInputName,
            imageTargetSize: imageTargetSize,
            imageOutputName: imageOutputName,
            textInput: textInput,
            textOutputName: textOutputName,
            embeddingDimension: configuration.embeddingDimension,
            poolingStrategy: configuration.poolingStrategy
        )

        CLIPLog.runtime.info("Resolved CLIP contract: imageInput=\(contract.imageInputName, privacy: .public) imageOutput=\(contract.imageOutputName, privacy: .public) textOutput=\(contract.textOutputName, privacy: .public)")
        return contract
    }

    private static func imageInputName(in model: MLModel) throws -> String {
        if let name = model.modelDescription.inputDescriptionsByName.first(where: { _, description in
            description.imageConstraint != nil
        })?.key {
            return name
        }
        throw CLIPError.invalidModelContract(stage: "image", reason: "No image input found")
    }

    private static func imageInputSize(in model: MLModel, inputName: String) -> CGSize? {
        guard let constraint = model.modelDescription.inputDescriptionsByName[inputName]?.imageConstraint else {
            return nil
        }
        return CGSize(width: constraint.pixelsWide, height: constraint.pixelsHigh)
    }

    private static func outputName(in model: MLModel, stage: String) throws -> String {
        let outputs = model.modelDescription.outputDescriptionsByName
        guard !outputs.isEmpty else {
            throw CLIPError.invalidModelContract(stage: stage, reason: "No outputs found")
        }

        let multiArrayNames = outputs.compactMap { name, description in
            description.type == .multiArray ? name : nil
        }
        guard !multiArrayNames.isEmpty else {
            throw CLIPError.invalidModelContract(stage: stage, reason: "No multi-array output found")
        }

        if multiArrayNames.count == 1 {
            return multiArrayNames[0]
        }

        let preferredSubstrings = ["embed", "projection", "feature", "output"]
        if let preferred = multiArrayNames.first(where: { name in
            let lower = name.lowercased()
            return preferredSubstrings.contains { lower.contains($0) }
        }) {
            CLIPLog.runtime.warning("Multiple CLIP \(stage, privacy: .public) outputs detected; choosing \(preferred, privacy: .public)")
            return preferred
        }

        let fallback = multiArrayNames[0]
        CLIPLog.runtime.warning("Ambiguous CLIP \(stage, privacy: .public) outputs; falling back to first multi-array output \(fallback, privacy: .public)")
        return fallback
    }

    private static func textInputContract(in model: MLModel) throws -> CLIPTextInputContract {
        if let stringInput = model.modelDescription.inputDescriptionsByName.first(where: { _, description in
            description.type == .string
        })?.key {
            return .string(inputName: stringInput)
        }

        let multiArrayInputs = model.modelDescription.inputDescriptionsByName.filter { _, description in
            description.type == .multiArray
        }
        guard !multiArrayInputs.isEmpty else {
            throw CLIPError.invalidModelContract(stage: "text", reason: "No supported text input (string or multi-array) found")
        }

        var idsName: String?
        var maskName: String?
        var tokenTypeName: String?
        for (name, _) in multiArrayInputs {
            let lower = name.lowercased()
            if idsName == nil, lower.contains("input") && lower.contains("id") {
                idsName = name
            } else if maskName == nil, lower.contains("mask") {
                maskName = name
            } else if tokenTypeName == nil, (lower.contains("token") && lower.contains("type")) || lower.contains("segment") {
                tokenTypeName = name
            }
        }

        if idsName == nil {
            idsName = multiArrayInputs.keys.first(where: { $0.lowercased().contains("id") })
        }
        if maskName == nil {
            maskName = multiArrayInputs.keys.first(where: { $0.lowercased().contains("mask") })
        }
        guard let idsName, let maskName else {
            throw CLIPError.invalidModelContract(stage: "text", reason: "Tokenized text model missing input_ids/attention_mask")
        }

        let sequenceLength = inferSequenceLength(from: multiArrayInputs[idsName])
            ?? inferSequenceLength(from: multiArrayInputs[maskName])
            ?? 77

        return .tokenized(
            inputIDsName: idsName,
            attentionMaskName: maskName,
            tokenTypeName: tokenTypeName,
            sequenceLength: sequenceLength
        )
    }

    private static func inferSequenceLength(from description: MLFeatureDescription?) -> Int? {
        guard let description,
              let constraint = description.multiArrayConstraint else { return nil }
        let shape = constraint.shape.map { $0.intValue }
        return shape.last.flatMap { $0 > 0 ? $0 : nil }
    }
}
