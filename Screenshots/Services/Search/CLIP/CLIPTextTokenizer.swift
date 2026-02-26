import Foundation
import OSLog

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
        // Integration point for a Hugging Face tokenizer adapter. Add the package,
        // implement CLIPTextTokenizing, then register it here at app startup.
        CLIPLog.tokenizer.debug("No default CLIP tokenizer adapter linked; tokenized text models will use lexical fallback until registered")
    }
}
