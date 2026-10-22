#if Zenzai || ZenzaiCPU
import llama
#endif

public import Foundation
import SwiftUtils

/// How likely the model finds an input reading itself, for callers that compare readings of the same keys (a word typed
/// in Latin letters read as the letters, or as romaji)
enum ZenzInputLikelihood {
    private static let inputTag = "\u{EE00}"
    private static let contextTag = "\u{EE02}"

    /// The log-probability of `input` after `leftSideContext` (its last 40 characters). Not of the output tag after it:
    /// how likely the input ends there says nothing about how it reads, and the user may still be typing it
    static func logProbability(context: ZenzContext, input: String, leftSideContext: String) -> Float? {
        let head = (leftSideContext.isEmpty ? "" : contextTag + String(leftSideContext.suffix(40))) + inputTag
        let headTokens = context.encode(head, addBOS: true)
        let tokens = context.encode(head + input, addBOS: true)
        guard tokens.starts(with: headTokens), tokens.count > headTokens.count else {
            return nil
        }
        let startOffset = headTokens.count - 1
        guard let logits = context.evaluationLogits(tokens: tokens, startOffset: startOffset) else {
            return nil
        }
        let vocabSize = context.vocabSize
        var total: Float = 0
        for position in headTokens.count ..< tokens.count {
            // The logits at the position before predict the token at this one
            let base = (position - 1 - startOffset) * vocabSize
            var maxLogit = -Float.infinity
            for index in 0 ..< vocabSize {
                maxLogit = max(maxLogit, logits[base + index])
            }
            var sum: Float = 0
            for index in 0 ..< vocabSize {
                sum += expf(logits[base + index] - maxLogit)
            }
            total += logits[base + Int(tokens[position])] - maxLogit - logf(sum)
        }
        return total
    }
}

extension KanaKanjiConverter {
    /// The log-probability Zenzai gives `input` (a reading in katakana, with letters typed as letters) after
    /// `leftSideContext`: how likely the model finds the reading itself, to compare readings of the same keys (token as
    /// letters, or とけん). Nil without the model. The model may be another than the conversion's: it then scores on the
    /// side, and the conversion keeps its model and its caches
    public func zenzaiInputLogProbability(_ input: String, leftSideContext: String = "", modelURL: URL) -> Float? {
        self.getScoringModel(modelURL: modelURL)?.inputLogProbability(input, leftSideContext: leftSideContext)
    }
}
