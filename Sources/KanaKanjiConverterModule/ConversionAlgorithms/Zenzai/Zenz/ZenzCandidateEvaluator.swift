#if Zenzai || ZenzaiCPU
import llama
#endif

import Algorithms
import EfficientNGram
import Foundation
import SwiftUtils

enum CandidateEvaluationResult: Sendable, Equatable, Hashable {
    case error
    case pass(score: Float, alternativeConstraints: [AlternativeConstraint], likelihood: Likelihood?)
    case fixRequired(prefixConstraint: [UInt8], likelihood: Likelihood?)
    case wholeResult(String)

    struct AlternativeConstraint: Sendable, Equatable, Hashable {
        var probabilityRatio: Float
        var prefixConstraint: [UInt8]
    }

    /// How probable the model finds the whole candidate, for choosing among candidates (see `Kana2Kanji.all_zenzai`):
    /// a candidate the model corrected token by token is not always the one it finds most probable as a whole
    struct Likelihood: Sendable, Equatable, Hashable {
        /// log P(candidate | prompt), with the bonus of learned words
        var text: Float
        /// log P(end | prompt, candidate): without it a candidate that stops short (初 for 初め) would always win
        var end: Float
        /// The token the model expects after the candidate when it is not the end: a word it would go on with
        var trailing: [UInt8]?

        var total: Float {
            self.text + self.end
        }
    }

    var likelihood: Likelihood? {
        switch self {
        case .pass(_, _, let likelihood), .fixRequired(_, let likelihood):
            likelihood
        case .error, .wholeResult:
            nil
        }
    }
}

struct ZenzEvaluationCacheKey: Sendable, Equatable, Hashable {
    struct CandidateSegment: Sendable, Equatable, Hashable {
        var word: String
        var ruby: String
        var isLearned: Bool
    }

    var prompt: String
    var candidateTextForEvaluation: String
    var originalCandidateText: String
    var prefixConstraint: Kana2Kanji.PrefixConstraint
    var requestRichCandidates: Bool
    var reusesAddressedPrefix: Bool
    var candidateSegments: [CandidateSegment]
}

/// モデル評価結果を少量だけ保持する、スレッドセーフなLRUキャッシュ。
final class ZenzEvaluationCache: @unchecked Sendable {
    private struct Entry {
        var result: CandidateEvaluationResult
        var accessIndex: UInt64
    }

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func value(for key: ZenzEvaluationCacheKey) -> CandidateEvaluationResult? {
        self.lock.withLock {
            guard var entry = self.entries[key] else {
                return nil
            }
            self.accessIndex &+= 1
            entry.accessIndex = self.accessIndex
            self.entries[key] = entry
            return entry.result
        }
    }

    func insert(_ result: CandidateEvaluationResult, for key: ZenzEvaluationCacheKey) {
        self.lock.withLock {
            self.accessIndex &+= 1
            if self.entries[key] == nil, self.entries.count >= self.capacity,
               let leastRecentlyUsedKey = self.entries.min(by: {
                   $0.value.accessIndex < $1.value.accessIndex
               })?.key {
                self.entries[leastRecentlyUsedKey] = nil
            }
            self.entries[key] = Entry(result: result, accessIndex: self.accessIndex)
        }
    }

    private let capacity: Int
    private var entries: [ZenzEvaluationCacheKey: Entry] = [:]
    private var accessIndex: UInt64 = 0
    private let lock = NSLock()
}

struct ZenzCandidateEvaluator {
    static func evaluate(
        context: ZenzContext,
        input: String,
        inputCursorPosition: Int? = nil,
        candidate: Candidate,
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        memoizationCache: ZenzaiMemoizationCache
    ) -> CandidateEvaluationResult {
        // 固定された部分は、表記を左文脈に移し、読みを入力から除いて、残りだけを評価する。
        // モデルは固定された表記が読みを消費したことを知らないので、残したまま評価すると続きの判断がずれる。
        guard let fixedPrefix = prefixConstraint.fixedPrefix,
              candidate.text.utf8.count >= fixedPrefix.byteCount,
              input.count >= fixedPrefix.rubyCount else {
            return self.evaluateAsIs(
                context: context,
                input: input,
                inputCursorPosition: inputCursorPosition,
                candidate: candidate,
                requestRichCandidates: requestRichCandidates,
                prefixConstraint: prefixConstraint,
                personalizationMode: personalizationMode,
                versionDependentConfig: versionDependentConfig,
                memoizationCache: memoizationCache
            )
        }
        let fixed = Array(prefixConstraint.constraint.prefix(fixedPrefix.byteCount))
        var remainingCandidate = candidate
        remainingCandidate.text = String(decoding: candidate.text.utf8.dropFirst(fixedPrefix.byteCount), as: UTF8.self)
        remainingCandidate.data = self.droppingFixedData(candidate.data, byteCount: fixedPrefix.byteCount)
        var remainingConstraint = prefixConstraint
        remainingConstraint.constraint = Array(prefixConstraint.constraint.dropFirst(fixedPrefix.byteCount))
        remainingConstraint.fixedPrefix = nil
        // The accepted prefix counts from the start of the whole text
        remainingConstraint.acceptedByteCount = max(0, prefixConstraint.acceptedByteCount - fixedPrefix.byteCount)
        let result = self.evaluateAsIs(
            context: context,
            input: String(input.dropFirst(fixedPrefix.rubyCount)),
            inputCursorPosition: inputCursorPosition.map { $0 - fixedPrefix.rubyCount },
            candidate: remainingCandidate,
            requestRichCandidates: requestRichCandidates,
            prefixConstraint: remainingConstraint,
            personalizationMode: personalizationMode,
            versionDependentConfig: self.appendingLeftSideContext(String(decoding: fixed, as: UTF8.self), to: versionDependentConfig),
            memoizationCache: memoizationCache
        )
        return self.prepending(fixed, to: result)
    }

    private static func evaluateAsIs(
        context: ZenzContext,
        input: String,
        inputCursorPosition: Int? = nil,
        candidate: Candidate,
        requestRichCandidates: Bool,
        prefixConstraint: Kana2Kanji.PrefixConstraint,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        memoizationCache: ZenzaiMemoizationCache
    ) -> CandidateEvaluationResult {
        debug("Evaluate", candidate)
        ZenzaiTrace.log("evaluate '\(candidate.text)' constraint '\(String(decoding: prefixConstraint.constraint, as: UTF8.self))'")
        var userDictionaryPrompt = ""
        for item in candidate.data where item.metadata.contains(.isFromUserDictionary) {
            userDictionaryPrompt += "\(item.word)(\(item.ruby.toHiragana()))"
        }
        let prompt = ZenzPromptBuilder.candidateEvaluationPrompt(
            input: input,
            inputCursorPosition: inputCursorPosition,
            userDictionaryPrompt: userDictionaryPrompt,
            versionDependentConfig: versionDependentConfig
        )
        let candidateTextForEvaluation = self.candidateTextForEvaluation(
            candidateText: candidate.text,
            input: input,
            inputCursorPosition: inputCursorPosition,
            versionDependentConfig: versionDependentConfig
        )
        let normalizedPrompt = context.normalizeForModel(prompt)
        let prevPrompt = context.previousEvaluationPrompt()
        let reusesAddressedPrefix = prevPrompt == normalizedPrompt && !requestRichCandidates
        // A cache hit must produce the same subsequent incremental-evaluation state
        // as a model evaluation.
        defer {
            context.setPreviousEvaluationPrompt(normalizedPrompt)
        }
        let cacheKey: ZenzEvaluationCacheKey? = if personalizationMode == nil {
            ZenzEvaluationCacheKey(
                prompt: prompt,
                candidateTextForEvaluation: candidateTextForEvaluation,
                originalCandidateText: candidate.text,
                prefixConstraint: prefixConstraint,
                requestRichCandidates: requestRichCandidates,
                reusesAddressedPrefix: reusesAddressedPrefix,
                candidateSegments: candidate.data.map {
                    .init(
                        word: $0.word,
                        ruby: $0.ruby,
                        isLearned: $0.metadata.contains(.isLearned)
                    )
                }
            )
        } else {
            nil
        }
        if let cacheKey, let cached = memoizationCache.cachedEvaluation(for: cacheKey) {
            return cached
        }
        func finish(_ result: CandidateEvaluationResult) -> CandidateEvaluationResult {
            if let cacheKey, result != .error {
                memoizationCache.cacheEvaluation(result, for: cacheKey)
            }
            return result
        }

        let promptTokens = context.encodeEvaluationPrompt(
            prompt,
            memoizationCache: memoizationCache
        )
        let candidateTokens = context.encode(candidateTextForEvaluation, addBOS: false, addEOS: false)
        let addressedTokens: [llama_token]
        if reusesAddressedPrefix {
            var prefix = ""
            for character in candidate.text {
                let newPrefix = prefix + String(character)
                if prefixConstraint.constraint.hasPrefix(newPrefix.utf8) {
                    prefix = newPrefix
                } else {
                    break
                }
            }
            addressedTokens = context.encode(prefix, addBOS: false, addEOS: false)
        } else {
            addressedTokens = []
        }

        let tokens = promptTokens + candidateTokens
        // The logits are taken from the end of the prompt for every token of the candidate and for the place after its
        // last one, so the probability of the whole candidate and of ending there are known. The agreement check still
        // starts after the addressed prefix, whose tokens the constraint settled.
        let logitsStartIndex = promptTokens.count - 1
        // The tokens of the accepted prefix (see `PrefixConstraint.acceptedByteCount`) are scored but not checked
        var acceptedTokenCount = 0
        if prefixConstraint.acceptedByteCount > 0 {
            var acceptedBytes = 0
            for token in candidateTokens where acceptedBytes < prefixConstraint.acceptedByteCount {
                acceptedBytes += context.tokenToPiece(token: token).count
                acceptedTokenCount += 1
            }
        }
        let firstCheckedIndex = promptTokens.count + max(addressedTokens.count, acceptedTokenCount)
        let n_vocab = Int(context.vocabSize)
        let learnedTokenPriorities: [Float]?
        if candidate.data.contains(where: { $0.metadata.contains(.isLearned) }) {
            let candidateLearnedTokens = candidate.data.flatMap {
                Array(
                    repeating: $0.metadata.contains(.isLearned) ? logf(self.learningPriority(data: $0)) : 0,
                    count: context.encode($0.word, addBOS: false).count
                )
            }
            if candidateLearnedTokens.count >= candidateTokens.count {
                learnedTokenPriorities = Array(candidateLearnedTokens.prefix(candidateTokens.count))
            } else {
                learnedTokenPriorities = candidateLearnedTokens + Array(
                    repeating: 0,
                    count: candidateTokens.count - candidateLearnedTokens.count
                )
            }
        } else {
            learnedTokenPriorities = nil
        }

        var score: Float = 0
        var textLogProbability: Float = 0
        var endLogProbability: Float = 0
        var trailing: [UInt8]?
        /// The constraint from the first disagreement, when the model wants another token
        var fixConstraint: [UInt8]?
        /// The candidate so far, when the model wants to end before the candidate does
        var wholeResult: String?

        struct AlternativeHighProbToken: Comparable {
            static func < (lhs: AlternativeHighProbToken, rhs: AlternativeHighProbToken) -> Bool {
                lhs.probabilityRatioToMaxProb < rhs.probabilityRatioToMaxProb
            }

            var token: llama_token
            var constraint: [UInt8]
            var probabilityRatioToMaxProb: Float
        }

        struct TokenAndLogit: Comparable {
            static func < (lhs: TokenAndLogit, rhs: TokenAndLogit) -> Bool {
                lhs.logit < rhs.logit
            }
            var token: llama_token
            var logit: Float
        }

        var altTokens = FixedSizeHeap<AlternativeHighProbToken>(size: requestRichCandidates ? 5 : 0)
        guard let logits = context.evaluationLogits(tokens: tokens, startOffset: logitsStartIndex) else {
            debug("logits unavailable")
            return .error
        }
        /// log of the sum of the exponentials of the logits at `startIndex`: the softmax normalizer
        func logSumExp(_ startIndex: Int) -> Float {
            var maximum = logits[startIndex]
            for vocabIndex in 1 ..< n_vocab {
                maximum = max(maximum, logits[startIndex + vocabIndex])
            }
            var sum: Float = 0
            for vocabIndex in 0 ..< n_vocab {
                sum += expf(logits[startIndex + vocabIndex] - maximum)
            }
            return maximum + logf(sum)
        }
        func bytes(_ tokens: ArraySlice<llama_token>) -> [UInt8] {
            tokens.reduce(into: []) { $0.append(contentsOf: context.tokenToPiece(token: $1).map { UInt8(bitPattern: $0) }) }
        }

        for i in promptTokens.count ... tokens.count {
            // The logits at i - 1 predict token i; i == tokens.count is the place after the candidate
            let startIndex = (i - 1 - logitsStartIndex) * n_vocab
            let endIndex = startIndex + n_vocab
            var tokenHeap = FixedSizeHeap<TokenAndLogit>(size: requestRichCandidates ? 3 : 0)
            let maxItem: TokenAndLogit

            if let (mode, baseLM, personalLM) = personalizationMode, mode.alpha > 0 {
                let prefix = tokens[..<i].dropFirst(promptTokens.count).map(Int.init)
                let baseProb: [Float]
                let personalProb: [Float]
                if !prefix.isEmpty {
                    baseProb = baseLM.bulkPredict(prefix).map { logf(Float($0) + 1e-7) }
                    personalProb = personalLM.bulkPredict(prefix).map { logf(Float($0) + 1e-7) }
                } else {
                    baseProb = Array(repeating: 0, count: n_vocab)
                    personalProb = baseProb
                }
                if requestRichCandidates {
                    for (vocabIndex, (lpb, lpp)) in zip(
                        0 ..< n_vocab,
                        zip(baseProb, personalProb)
                    ) {
                        let personalizedLogit = logits[startIndex + vocabIndex]
                            + mode.alpha * (lpp - lpb)
                        tokenHeap.insertIfPossible(
                            TokenAndLogit(
                                token: llama_token(vocabIndex),
                                logit: personalizedLogit
                            )
                        )
                    }
                    guard let maximum = tokenHeap.max else {
                        debug("Max Item could not be found for unknown reason")
                        return .error
                    }
                    maxItem = maximum
                } else {
                    var maximum = TokenAndLogit(
                        token: 0,
                        logit: logits[startIndex] + mode.alpha * (personalProb[0] - baseProb[0])
                    )
                    for vocabIndex in 1 ..< n_vocab {
                        let personalizedLogit = logits[startIndex + vocabIndex]
                            + mode.alpha * (personalProb[vocabIndex] - baseProb[vocabIndex])
                        if personalizedLogit > maximum.logit {
                            maximum = TokenAndLogit(
                                token: llama_token(vocabIndex),
                                logit: personalizedLogit
                            )
                        }
                    }
                    maxItem = maximum
                }
            } else if requestRichCandidates {
                for index in startIndex ..< endIndex {
                    tokenHeap.insertIfPossible(
                        TokenAndLogit(
                            token: llama_token(index - startIndex),
                            logit: logits[index]
                        )
                    )
                }
                guard let maximum = tokenHeap.max else {
                    debug("Max Item could not be found for unknown reason")
                    return .error
                }
                maxItem = maximum
            } else {
                var maximumToken = 0
                var maximumLogit = logits[startIndex]
                for vocabIndex in 1 ..< n_vocab {
                    let logit = logits[startIndex + vocabIndex]
                    if logit > maximumLogit {
                        maximumToken = vocabIndex
                        maximumLogit = logit
                    }
                }
                maxItem = TokenAndLogit(
                    token: llama_token(maximumToken),
                    logit: maximumLogit
                )
            }

            let normalizer = logSumExp(startIndex)
            if i == tokens.count {
                endLogProbability = logits[startIndex + Int(context.eosToken)] - normalizer
                if maxItem.token != context.eosToken {
                    trailing = context.tokenToPiece(token: maxItem.token).map { UInt8(bitPattern: $0) }
                }
                break
            }
            let tokenID = tokens[i]
            let candidateTokenIndex = i - promptTokens.count
            let learnedPriority = learnedTokenPriorities.map {
                candidateTokenIndex < $0.count ? $0[candidateTokenIndex] : 0
            } ?? 0
            textLogProbability += logits[startIndex + Int(tokenID)] + learnedPriority - normalizer
            guard i >= firstCheckedIndex, fixConstraint == nil, wholeResult == nil else {
                // The addressed prefix, or the tokens after the first disagreement: only their probability is wanted
                continue
            }

            if maxItem.token != tokenID {
                ZenzaiTrace.log("mismatch at token \(candidateTokenIndex): candidate '\(context.decodeTokens([tokenID]))' logit \(logits[startIndex + Int(tokenID)]) vs model '\(context.decodeTokens([maxItem.token]))' logit \(maxItem.logit)")
                if maxItem.token == context.eosToken {
                    let string = String(data: Data(bytes(tokens[..<i])), encoding: .utf8) ?? ""
                    wholeResult = String(string.dropFirst(normalizedPrompt.count))
                } else {
                    // softmaxの正規化項は両辺で相殺されるため、logitのまま比較できる。
                    let preferLearnedToken = learnedPriority > 0
                        && logits[startIndex + Int(tokenID)] + learnedPriority > maxItem.logit
                    if !preferLearnedToken {
                        let constraint = bytes(tokens[..<i]) + context.tokenToPiece(token: maxItem.token).map { UInt8(bitPattern: $0) }
                        fixConstraint = Array(constraint.dropFirst(normalizedPrompt.utf8.count))
                    }
                }
            } else if requestRichCandidates {
                tokenHeap.removeMax()
                let prefix = bytes(tokens[..<i]).dropFirst(normalizedPrompt.utf8.count)
                for item in tokenHeap.unordered {
                    altTokens.insertIfPossible(
                        AlternativeHighProbToken(
                            token: item.token,
                            constraint: Array(prefix) + context.tokenToPiece(token: item.token).map { UInt8(bitPattern: $0) },
                            probabilityRatioToMaxProb: expf(item.logit - maxItem.logit)
                        )
                    )
                }
            }
            // この値は順位付けには使われない。正規化項の全語彙走査を避けるため、
            // 等価な順位を持つ未正規化logitを蓄積する。
            score += maxItem.logit
        }
        let likelihood = CandidateEvaluationResult.Likelihood(text: textLogProbability, end: endLogProbability, trailing: trailing)
        if let wholeResult {
            return finish(.wholeResult(wholeResult))
        }
        if let fixConstraint {
            return finish(.fixRequired(prefixConstraint: fixConstraint, likelihood: likelihood))
        }
        return finish(
            .pass(
                score: score,
                alternativeConstraints: altTokens.unordered.sorted(by: >).map {
                    .init(probabilityRatio: $0.probabilityRatioToMaxProb, prefixConstraint: $0.constraint)
                },
                likelihood: likelihood
            )
        )
    }

    static func candidateTextForEvaluation(
        candidateText: String,
        input: String,
        inputCursorPosition: Int?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode
    ) -> String {
        switch versionDependentConfig {
        case .v2:
            return candidateText
        case .v3(let mode):
            if mode.enableAlignmentSeparator,
               ZenzPromptBuilder.shouldInsertAlignmentSeparator(input: input, cursorPosition: inputCursorPosition) {
                return candidateText + ZenzPromptBuilder.alignmentSeparator
            }
            return candidateText
        }
    }

    /// `data` の先頭から、表記全体が固定部分に収まる要素だけを落とす
    static func droppingFixedData(_ data: [DicdataElement], byteCount: Int) -> [DicdataElement] {
        var coveredByteCount = 0
        return Array(
            data.drop { element in
                let nextCoveredByteCount = coveredByteCount + element.word.utf8.count
                guard nextCoveredByteCount <= byteCount else {
                    return false
                }
                coveredByteCount = nextCoveredByteCount
                return true
            }
        )
    }

    private static func appendingLeftSideContext(_ text: String, to config: ConvertRequestOptions.ZenzaiVersionDependentMode) -> ConvertRequestOptions.ZenzaiVersionDependentMode {
        switch config {
        case .v2(var mode):
            mode.leftSideContext = (mode.leftSideContext ?? "") + text
            return .v2(mode)
        case .v3(var mode):
            mode.leftSideContext = (mode.leftSideContext ?? "") + text
            return .v3(mode)
        }
    }

    /// 固定された表記を除いて評価した結果の制約に、その表記を戻す
    private static func prepending(_ fixed: [UInt8], to result: CandidateEvaluationResult) -> CandidateEvaluationResult {
        switch result {
        case .error:
            return .error
        case .pass(let score, let alternativeConstraints, let likelihood):
            return .pass(
                score: score,
                alternativeConstraints: alternativeConstraints.map {
                    .init(probabilityRatio: $0.probabilityRatio, prefixConstraint: fixed + $0.prefixConstraint)
                },
                likelihood: likelihood
            )
        case .fixRequired(let prefixConstraint, let likelihood):
            return .fixRequired(prefixConstraint: fixed + prefixConstraint, likelihood: likelihood)
        case .wholeResult(let wholeResult):
            return .wholeResult(String(decoding: fixed, as: UTF8.self) + wholeResult)
        }
    }

    private static func learningPriority(data: DicdataElement) -> Float {
        // 文字数の長い候補ほど優先的に適用されるようにする
        // 積極的な複合語化の効果を期待
        if 1 <= data.ruby.count && data.ruby.count <= 4 {
            Float(data.ruby.count + 2)
        } else if 5 <= data.ruby.count && data.ruby.count <= 15 {
            Float(data.ruby.count * 2)
        } else {
            30
        }
    }
}

/// Prints the steps of a Zenzai conversion to standard output when the environment has `OGURA_ZENZAI_TRACE=1`, for the
/// evaluation harnesses: a release build prints nothing through `debug`
enum ZenzaiTrace {
    static let enabled = ProcessInfo.processInfo.environment["OGURA_ZENZAI_TRACE"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        if self.enabled {
            print("ZENZAI " + message())
        }
    }

    static func describe(_ result: CandidateEvaluationResult) -> String {
        switch result {
        case .error:
            "error"
        case .pass(_, let alternatives, let likelihood):
            "pass (\(self.describe(likelihood)), \(alternatives.count) alternatives)"
        case .fixRequired(let constraint, let likelihood):
            "fix required: \(String(decoding: constraint, as: UTF8.self)) (\(self.describe(likelihood)))"
        case .wholeResult(let text):
            "whole result: \(text)"
        }
    }

    private static func describe(_ likelihood: CandidateEvaluationResult.Likelihood?) -> String {
        guard let likelihood else {
            return "no likelihood"
        }
        let trailing = likelihood.trailing.map { " then '\(String(decoding: $0, as: UTF8.self))'" } ?? ""
        return "log p \(likelihood.text) end \(likelihood.end)\(trailing)"
    }
}
