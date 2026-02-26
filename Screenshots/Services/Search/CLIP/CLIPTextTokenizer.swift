import Foundation
import OSLog
#if canImport(Tokenizers)
import Tokenizers
#endif

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
        CLIPLog.tokenizer.info("Registered CLIP text tokenizer adapter")
    }

    func clearTokenizer() {
        tokenizer = nil
        CLIPLog.tokenizer.info("Cleared CLIP text tokenizer adapter")
    }

    func encode(_ text: String, maxLength: Int) -> CLIPTokenizedText? {
        tokenizer?.encode(text, maxLength: maxLength)
    }

    func hasTokenizer() -> Bool {
        tokenizer != nil
    }
}

enum CLIPTokenizerBootstrap {
    static func registerDefaultTokenizerIfAvailable() {
        #if canImport(Tokenizers)
        Task.detached(priority: .utility) {
            await loadAndRegisterBundledSwiftTransformersTokenizer()
        }
        #else
        CLIPLog.tokenizer.debug("Tokenizers product not linked; tokenized text models will use lexical fallback until registered")
        #endif
    }
}

#if canImport(Tokenizers)
private extension CLIPTokenizerBootstrap {
    static func loadAndRegisterBundledSwiftTransformersTokenizer() async {
        guard let folder = bundledTokenizerFolder() else {
            CLIPLog.tokenizer.info("No bundled tokenizer resources found (expected tokenizer.json + tokenizer_config.json)")
            return
        }

        do {
            let tokenizer = try await AutoTokenizer.from(modelFolder: folder)
            let adapter = SwiftTransformersCLIPTokenizerAdapter(tokenizer: tokenizer)
            await CLIPTextTokenizerRegistry.shared.setTokenizer(adapter)
            CLIPLog.tokenizer.info("Loaded bundled CLIP tokenizer from \(folder.lastPathComponent, privacy: .public)")
        } catch {
            CLIPLog.tokenizer.error("Failed to load bundled CLIP tokenizer: \(String(describing: error), privacy: .public)")
        }
    }

    static func bundledTokenizerFolder() -> URL? {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: "CLIPTokenizer", withExtension: nil),
            bundle.url(forResource: "clip-tokenizer", withExtension: nil),
            bundle.url(forResource: "Tokenizer", withExtension: nil),
            bundle.resourceURL
        ]

        for candidate in candidates.compactMap({ $0 }) {
            let tokenizerJSON = candidate.appendingPathComponent("tokenizer.json")
            let tokenizerConfigJSON = candidate.appendingPathComponent("tokenizer_config.json")
            if FileManager.default.fileExists(atPath: tokenizerJSON.path),
               FileManager.default.fileExists(atPath: tokenizerConfigJSON.path) {
                return candidate
            }
        }

        return nil
    }
}

private final class SwiftTransformersCLIPTokenizerAdapter: CLIPTextTokenizing, @unchecked Sendable {
    private let tokenizer: Tokenizer
    private let padTokenID: Int
    private let eosTokenID: Int?

    init(tokenizer: Tokenizer) {
        self.tokenizer = tokenizer
        self.eosTokenID = Self.resolveTokenID(in: tokenizer, candidates: ["<|endoftext|>", "</s>", "[SEP]"])
        self.padTokenID = Self.resolveTokenID(in: tokenizer, candidates: ["[PAD]", "<pad>", "</s>", "<|endoftext|>"]) ?? 0
    }

    func encode(_ text: String, maxLength: Int) -> CLIPTokenizedText? {
        guard maxLength > 0 else { return nil }

        var tokenIDs = tokenizer.encode(text: text)
        if tokenIDs.isEmpty {
            return nil
        }

        if tokenIDs.count > maxLength {
            tokenIDs = Array(tokenIDs.prefix(maxLength))
            if let eosTokenID {
                tokenIDs[tokenIDs.count - 1] = eosTokenID
            }
        }

        let actualCount = tokenIDs.count
        if actualCount < maxLength {
            tokenIDs.append(contentsOf: Array(repeating: padTokenID, count: maxLength - actualCount))
        }

        let attentionMask: [Int32] = (0..<maxLength).map { index in
            index < actualCount ? 1 : 0
        }

        let inputIDs = tokenIDs.map { value in
            Int32(clamping: value)
        }

        return CLIPTokenizedText(inputIDs: inputIDs, attentionMask: attentionMask, maxLength: maxLength)
    }

    private static func resolveTokenID(in tokenizer: Tokenizer, candidates: [String]) -> Int? {
        for token in candidates {
            if let id = tokenizer.convertTokenToId(token) {
                return id
            }
        }
        return nil
    }
}
#endif
