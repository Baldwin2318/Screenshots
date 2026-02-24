import Foundation
import NaturalLanguage
import UIKit
import Vision

struct ClassificationResult {
    let categories: [String]
    let labels: [String]
    let extractedText: String
    let topicTags: [String]
}

enum ScreenshotClassifier {
    static func classify(image: UIImage) async -> ClassificationResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let cgImage = image.cgImage else {
                    continuation.resume(returning: ClassificationResult(categories: ["Quick Notes"], labels: [], extractedText: "", topicTags: []))
                    return
                }

                let textRequest = VNRecognizeTextRequest()
                textRequest.recognitionLevel = .accurate
                textRequest.usesLanguageCorrection = true

                let imageRequest = VNClassifyImageRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

                do {
                    try handler.perform([textRequest, imageRequest])

                    let lines = textRequest.results?
                        .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty } ?? []

                    let extractedText = lines.joined(separator: "\n")
                    let labels = imageRequest.results?
                        .prefix(20)
                        .map { $0.identifier.replacingOccurrences(of: "_", with: " ").lowercased() } ?? []

                    let keywords = extractKeywords(from: ([extractedText] + labels).joined(separator: " "))
                    let topics = Array(keywords.prefix(6)).map { titleCase($0) }

                    let fallbackCollections: [String]
                    if let first = topics.first {
                        fallbackCollections = ["\(first) Notes"]
                    } else {
                        fallbackCollections = ["Quick Notes"]
                    }

                    continuation.resume(returning: ClassificationResult(
                        categories: fallbackCollections,
                        labels: labels,
                        extractedText: extractedText,
                        topicTags: topics
                    ))
                } catch {
                    continuation.resume(returning: ClassificationResult(categories: ["Quick Notes"], labels: [], extractedText: "", topicTags: []))
                }
            }
        }
    }

    static func extractKeywords(from input: String) -> [String] {
        let text = input.lowercased()
        guard !text.isEmpty else { return [] }

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text

        var counts: [String: Int] = [:]
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, range in
            guard let tag, tag == .noun || tag == .adjective else { return true }
            let word = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard word.count > 2 else { return true }
            guard !CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: word)) else { return true }

            counts[word, default: 0] += 1
            return true
        }

        return counts
            .sorted {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value > $1.value
            }
            .map(\.key)
            .prefix(10)
            .map { $0 }
    }

    static func titleCase(_ value: String) -> String {
        value
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
