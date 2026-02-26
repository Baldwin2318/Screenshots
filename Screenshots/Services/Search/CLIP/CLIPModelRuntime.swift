import Accelerate
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import OSLog
import UIKit

final class CLIPModelRuntime {
    private let imageModel: MLModel
    private let textModel: MLModel
    private let contract: CLIPResolvedContract

    init(bundle: Bundle, configuration: CLIPRuntimeConfiguration = .default) throws {
        imageModel = try Self.loadModel(named: configuration.imageModelName, in: bundle)
        textModel = try Self.loadModel(named: configuration.textModelName, in: bundle)
        contract = try CLIPModelContractResolver.resolve(
            imageModel: imageModel,
            textModel: textModel,
            configuration: configuration
        )
    }

    func imageEmbedding(for image: UIImage) throws -> [Float] {
        guard let pixelBuffer = Self.makePixelBuffer(
            from: image,
            size: contract.imageTargetSize ?? CGSize(width: 224, height: 224)
        ) else {
            throw CLIPError.imagePreprocessingFailed(reason: "Unable to create pixel buffer")
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
            contract.imageInputName: MLFeatureValue(pixelBuffer: pixelBuffer)
        ]) else {
            throw CLIPError.featureProviderCreationFailed(stage: "image")
        }

        do {
            let output = try imageModel.prediction(from: provider)
            return try Self.extractEmbedding(
                from: output,
                outputName: contract.imageOutputName,
                stage: "image",
                embeddingDimension: contract.embeddingDimension,
                poolingStrategy: contract.poolingStrategy
            )
        } catch let error as CLIPError {
            throw error
        } catch {
            throw CLIPError.predictionFailed(stage: "image", message: String(describing: error))
        }
    }

    func textEmbedding(for query: String) async throws -> [Float] {
        switch contract.textInput {
        case .string(let inputName):
            guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
                inputName: MLFeatureValue(string: query)
            ]) else {
                throw CLIPError.featureProviderCreationFailed(stage: "text")
            }

            do {
                let output = try await textModel.prediction(from: provider)
                return try Self.extractEmbedding(
                    from: output,
                    outputName: contract.textOutputName,
                    stage: "text",
                    embeddingDimension: contract.embeddingDimension,
                    poolingStrategy: contract.poolingStrategy
                )
            } catch let error as CLIPError {
                throw error
            } catch {
                throw CLIPError.predictionFailed(stage: "text", message: String(describing: error))
            }

        case .tokenized(let idsName, let maskName, let tokenTypeName, let sequenceLength):
            guard let tokenized = await CLIPTextTokenizerRegistry.shared.encode(query, maxLength: sequenceLength) else {
                let hasTokenizer = await CLIPTextTokenizerRegistry.shared.hasTokenizer()
                if !hasTokenizer {
                    throw CLIPError.tokenizerRequired(sequenceLength: sequenceLength)
                }
                throw CLIPError.invalidModelContract(stage: "text", reason: "Tokenizer failed to produce tokenized text")
            }

            guard let idsArray = Self.makeInt32MultiArray(tokenized.inputIDs),
                  let maskArray = Self.makeInt32MultiArray(tokenized.attentionMask) else {
                throw CLIPError.featureProviderCreationFailed(stage: "text.tokenized")
            }

            var features: [String: MLFeatureValue] = [
                idsName: MLFeatureValue(multiArray: idsArray),
                maskName: MLFeatureValue(multiArray: maskArray)
            ]

            if let tokenTypeName,
               let tokenTypeArray = Self.makeInt32MultiArray([Int32](repeating: 0, count: tokenized.maxLength)) {
                features[tokenTypeName] = MLFeatureValue(multiArray: tokenTypeArray)
            }

            guard let provider = try? MLDictionaryFeatureProvider(dictionary: features) else {
                throw CLIPError.featureProviderCreationFailed(stage: "text.tokenized")
            }

            do {
                let output = try await textModel.prediction(from: provider)
                return try Self.extractEmbedding(
                    from: output,
                    outputName: contract.textOutputName,
                    stage: "text",
                    embeddingDimension: contract.embeddingDimension,
                    poolingStrategy: contract.poolingStrategy
                )
            } catch let error as CLIPError {
                throw error
            } catch {
                throw CLIPError.predictionFailed(stage: "text", message: String(describing: error))
            }
        }
    }

    private static func loadModel(named name: String, in bundle: Bundle) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine

        guard let modelURL = bundle.url(forResource: name, withExtension: "mlmodelc") else {
            throw CLIPError.missingCompiledModel(name: name)
        }

        do {
            return try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            throw CLIPError.modelLoadFailed(name: name, message: String(describing: error))
        }
    }

    private static func extractEmbedding(
        from provider: MLFeatureProvider,
        outputName: String,
        stage: String,
        embeddingDimension: Int,
        poolingStrategy: CLIPEmbeddingPoolingStrategy
    ) throws -> [Float] {
        guard let outputValue = provider.featureValue(for: outputName) else {
            throw CLIPError.outputMissing(stage: stage, outputName: outputName)
        }
        guard let array = outputValue.multiArrayValue else {
            throw CLIPError.embeddingExtractionFailed(stage: stage, reason: "Output '\(outputName)' is not MLMultiArray")
        }

        let values = try floatArray(from: array, stage: stage)
        let pooled = try collapseEmbedding(
            values,
            stage: stage,
            embeddingDimension: embeddingDimension,
            strategy: poolingStrategy
        )
        return EmbeddingCodec.normalize(pooled)
    }

    private static func collapseEmbedding(
        _ values: [Float],
        stage: String,
        embeddingDimension: Int,
        strategy: CLIPEmbeddingPoolingStrategy
    ) throws -> [Float] {
        guard !values.isEmpty else {
            throw CLIPError.embeddingExtractionFailed(stage: stage, reason: "Empty embedding output")
        }

        switch strategy {
        case .exact:
            guard values.count == embeddingDimension else {
                throw CLIPError.embeddingExtractionFailed(
                    stage: stage,
                    reason: "Expected \(embeddingDimension) values, got \(values.count)"
                )
            }
            return values

        case .meanRowsOrPrefix:
            if values.count == embeddingDimension {
                return values
            }
            if values.count > embeddingDimension, values.count % embeddingDimension == 0 {
                let rows = values.count / embeddingDimension
                var pooled = [Float](repeating: 0, count: embeddingDimension)
                for row in 0..<rows {
                    let base = row * embeddingDimension
                    for col in 0..<embeddingDimension {
                        pooled[col] += values[base + col]
                    }
                }
                var divisor = Float(rows)
                pooled.withUnsafeMutableBufferPointer { buffer in
                    vDSP_vsdiv(buffer.baseAddress!, 1, &divisor, buffer.baseAddress!, 1, vDSP_Length(embeddingDimension))
                }
                return pooled
            }
            if values.count >= embeddingDimension {
                CLIPLog.runtime.warning("Unexpected CLIP embedding count \(values.count, privacy: .public) for \(stage, privacy: .public); truncating to \(embeddingDimension, privacy: .public)")
                return Array(values.prefix(embeddingDimension))
            }
            throw CLIPError.embeddingExtractionFailed(
                stage: stage,
                reason: "Embedding shorter than expected (\(values.count) < \(embeddingDimension))"
            )
        }
    }

    private static func floatArray(from multiArray: MLMultiArray, stage: String) throws -> [Float] {
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
                result[idx] = float32FromFloat16(pointer[idx])
            }
        case .int32:
            let pointer = multiArray.dataPointer.bindMemory(to: Int32.self, capacity: count)
            for idx in 0..<count { result[idx] = Float(pointer[idx]) }
        default:
            throw CLIPError.embeddingExtractionFailed(
                stage: stage,
                reason: "Unsupported MLMultiArray data type: \(multiArray.dataType.rawValue)"
            )
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
