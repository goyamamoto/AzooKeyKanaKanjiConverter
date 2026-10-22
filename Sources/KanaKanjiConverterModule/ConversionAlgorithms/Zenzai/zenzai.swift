import Algorithms
import EfficientNGram
import Foundation
import SwiftUtils

extension Kana2Kanji {
    struct ZenzaiCache {
        init(
            _ inputData: ComposingText,
            constraint: PrefixConstraint,
            satisfyingCandidate: Candidate?,
            evaluatedSatisfyingCandidate: Candidate? = nil,
            prefixCandidate: Candidate? = nil,
            lattice: Lattice? = nil
        ) {
            self.inputData = inputData
            self.prefixConstraint = constraint
            self.satisfyingCandidate = satisfyingCandidate
            self.evaluatedSatisfyingCandidate = evaluatedSatisfyingCandidate
            self.prefixCandidate = prefixCandidate
            self.cachedLattice = lattice
            self.cachedLatticeInputData = lattice == nil ? nil : inputData
        }

        private init(
            _ inputData: ComposingText,
            constraint: PrefixConstraint,
            satisfyingCandidate: Candidate?,
            evaluatedSatisfyingCandidate: Candidate?,
            prefixCandidate: Candidate?,
            cachedLattice: Lattice?,
            cachedLatticeInputData: ComposingText?
        ) {
            self.inputData = inputData
            self.prefixConstraint = constraint
            self.satisfyingCandidate = satisfyingCandidate
            self.evaluatedSatisfyingCandidate = evaluatedSatisfyingCandidate
            self.prefixCandidate = prefixCandidate
            self.cachedLattice = cachedLattice
            self.cachedLatticeInputData = cachedLatticeInputData
        }

        private var prefixConstraint: PrefixConstraint
        private var satisfyingCandidate: Candidate?
        private(set) var evaluatedSatisfyingCandidate: Candidate?
        /// 入力の先頭が決まっている候補。読みが入力の先頭に残っている間、表記を固定部分にする。
        private(set) var prefixCandidate: Candidate?
        private var inputData: ComposingText
        private var cachedLattice: Lattice?
        private var cachedLatticeInputData: ComposingText?

        /// 共有済みの変換結果を使う場合、現在の制約だけを更新し、直近の完全な
        /// ラティスは次の未キャッシュ入力の差分構築用アンカーとして保持する。
        func updatingResult(
            for newInputData: ComposingText,
            constraint: PrefixConstraint,
            satisfyingCandidate: Candidate
        ) -> ZenzaiCache {
            ZenzaiCache(
                newInputData,
                constraint: constraint,
                satisfyingCandidate: satisfyingCandidate,
                evaluatedSatisfyingCandidate: satisfyingCandidate,
                prefixCandidate: self.prefixCandidate(remainingIn: newInputData),
                cachedLattice: self.cachedLattice,
                cachedLatticeInputData: self.cachedLatticeInputData
            )
        }

        /// 先頭の候補を設定し、以降の変換で先頭の制約として使う。
        /// 直近のラティスは差分構築用に保持する。
        func settingPrefixCandidate(_ candidate: Candidate) -> ZenzaiCache {
            ZenzaiCache(
                self.inputData,
                constraint: self.prefixConstraint,
                satisfyingCandidate: candidate,
                evaluatedSatisfyingCandidate: candidate,
                prefixCandidate: candidate,
                cachedLattice: self.cachedLattice,
                cachedLatticeInputData: self.cachedLatticeInputData
            )
        }

        func getNewConstraint(for newInputData: ComposingText) -> PrefixConstraint {
            self.fixingPrefix(self.getReplaceableConstraint(for: newInputData), for: newInputData)
        }

        /// The constraint of a conversion that starts over: only the candidate fixed at the head, when there is one
        func getFreshConstraint(for newInputData: ComposingText) -> PrefixConstraint {
            self.fixingPrefix(PrefixConstraint([]), for: newInputData)
        }

        /// 先頭の候補の読みが入力の先頭にそのまま残っていればその候補。残っていなければ nil で、以降は引き継がない。
        func prefixCandidate(remainingIn newInputData: ComposingText) -> Candidate? {
            guard let prefixCandidate,
                  newInputData.convertTarget.toKatakana().hasPrefix(prefixCandidate.data.map(\.ruby).joined()) else {
                return nil
            }
            return prefixCandidate
        }

        /// 先頭の候補の読みが入力の先頭にそのまま残っている間、その表記を固定部分にする。
        /// 制約が表記で始まっていればその長さを固定し、始まっていなければ表記で置き換える。
        private func fixingPrefix(_ constraint: PrefixConstraint, for newInputData: ComposingText) -> PrefixConstraint {
            guard let prefixCandidate = self.prefixCandidate(remainingIn: newInputData) else {
                return constraint
            }
            let fixed = Array(prefixCandidate.data.map(\.word).joined().utf8)
            let fixedPrefix = PrefixConstraint.FixedPrefix(
                byteCount: fixed.count,
                rubyCount: prefixCandidate.data.map(\.ruby).joined().count
            )
            if constraint.constraint.hasPrefix(fixed) {
                var fixedConstraint = constraint
                fixedConstraint.fixedPrefix = fixedPrefix
                return fixedConstraint
            }
            return PrefixConstraint(fixed, fixedPrefix: fixedPrefix)
        }

        /// モデルの評価で置き換わりうる制約。
        private func getReplaceableConstraint(for newInputData: ComposingText) -> PrefixConstraint {
            if let satisfyingCandidate {
                var current = newInputData.convertTarget.toKatakana()[...]
                var constraint = [UInt8]()
                for item in satisfyingCandidate.data {
                    if current.hasPrefix(item.ruby) {
                        constraint += item.word.utf8
                        current = current.dropFirst(item.ruby.count)
                    }
                }
                // What was accepted at the last key (the model's correction could not be made) is not carried over: the
                // dictionary often could not make the correction only because the reading was unfinished (追記ゅ while
                // 追求 is typed), and the words would stay as they were when it can
                return PrefixConstraint(constraint)
            } else if newInputData.convertTarget.hasPrefix(inputData.convertTarget) {
                // hasEOSの場合は落とすために改めて作り直す
                return PrefixConstraint(self.prefixConstraint.constraint)
            } else {
                return PrefixConstraint([])
            }
        }

        func getPreprocessedLattice(for newInputData: ComposingText, kanaKanji: Kana2Kanji, dicdataStoreState: DicdataStoreState) -> Lattice? {
            guard let cachedLattice, let cachedLatticeInputData else { return nil }

            // 同じComposingTextなら既存のlatticeをそのまま返す
            if newInputData.input == cachedLatticeInputData.input
                && newInputData.convertTarget == cachedLatticeInputData.convertTarget {
                cachedLattice.resetNodeStates()
                return cachedLattice
            }

            // 逐次入力の場合は差分更新でlatticeを構築
            return kanaKanji.buildLatticeWithIncrementalCache(
                inputData: newInputData,
                inputCount: newInputData.input.count,
                surfaceCount: newInputData.convertTarget.count,
                incrementalCacheInfo: (inputData: cachedLatticeInputData, lattice: cachedLattice),
                dicdataStoreState: dicdataStoreState
            )
        }
    }

    struct PrefixConstraint: Sendable, Equatable, Hashable, CustomStringConvertible {
        /// 先頭の決まっている部分。モデルはこの表記を左文脈、この読みを入力済みとして扱い、評価しない。
        struct FixedPrefix: Sendable, Equatable, Hashable {
            /// `constraint` の先頭のうち、固定された表記の byte 数
            var byteCount: Int
            /// 入力 (カタカナ) の先頭のうち、その表記が読んだ文字数
            var rubyCount: Int
        }

        init(_ constraint: [UInt8], hasEOS: Bool = false, ignoreMemoryAndUserDictionary: Bool = false, fixedPrefix: FixedPrefix? = nil, acceptedByteCount: Int = 0) {
            self.constraint = constraint
            self.hasEOS = hasEOS
            self.ignoreMemoryAndUserDictionary = ignoreMemoryAndUserDictionary
            self.fixedPrefix = fixedPrefix
            self.acceptedByteCount = acceptedByteCount
        }

        var constraint: [UInt8]
        var hasEOS: Bool
        var ignoreMemoryAndUserDictionary: Bool
        var fixedPrefix: FixedPrefix?
        /// The candidate's text up to this many bytes is taken as it is: the model's disagreements there are not acted
        /// on (its corrections could not be made), but unlike a fixed prefix it stays in what the model sees and scores
        var acceptedByteCount: Int = 0

        var description: String {
            "PrefixConstraint(constraint: \"\(String(decoding: self.constraint, as: UTF8.self))\", hasEOS: \(self.hasEOS), ignoreMemoryAndUserDictionary: \(self.ignoreMemoryAndUserDictionary), fixedPrefix: \(String(describing: self.fixedPrefix)), accepted: \(self.acceptedByteCount))"
        }

        var isEmpty: Bool {
            self.constraint.isEmpty && !self.hasEOS
        }
    }

    /// zenzaiシステムによる完全変換。
    /// A second model that scores the likeliest candidates of a thorough conversion too (see `ZenzaiMode.SecondOpinion`)
    struct SecondOpinion {
        var model: Zenz
        var weight: Float
        var threshold: Float
        var memoizationCache: ZenzaiMemoizationCache
    }
    /// How many of the likeliest candidates the second model scores
    static let secondOpinionCandidateCount = 4

    func all_zenzai(
        _ inputData: ComposingText,
        zenz: Zenz,
        zenzaiCache: ZenzaiCache?,
        zenzaiMemoizationCache: ZenzaiMemoizationCache,
        inferenceLimit: Int,
        requestRichCandidates: Bool,
        thorough: Bool = false,
        secondOpinion: SecondOpinion? = nil,
        personalizationMode: (mode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode, base: EfficientNGram, personal: EfficientNGram)?,
        versionDependentConfig: ConvertRequestOptions.ZenzaiVersionDependentMode,
        dicdataStoreState: DicdataStoreState,
        cancellation: ConvertRequestOptions.ZenzaiMode.Cancellation? = nil
    ) -> (result: LatticeNode, lattice: Lattice, cache: ZenzaiCache) {
        let latticeInputData = Self.zenzaiLatticeInputData(for: inputData)
        let zenzInputCursorPosition = Self.zenzaiInputCursorPosition(for: inputData)
        let inputStyle = inputData.input.last?.inputStyle ?? .direct
        let defersEvaluationForPendingInput = !requestRichCandidates
            && !thorough
            && personalizationMode == nil
            && self.resolvePredictiveInputSource(
                composingText: inputData,
                inputStyle: inputStyle
            ).droppedSuffixCount > 0
        // A thorough conversion (for committing) starts over from the dictionary's own conversion instead of the prefix
        // the model settled on key by key; the two, and the model's other readings, are compared by their probability
        // (see `choosing` below)
        var constraint = if thorough {
            zenzaiCache?.getFreshConstraint(for: latticeInputData) ?? PrefixConstraint([])
        } else {
            zenzaiCache?.getNewConstraint(for: latticeInputData) ?? PrefixConstraint([])
        }
        let prefixCandidate = zenzaiCache?.prefixCandidate(remainingIn: latticeInputData)
        let sharesResults = !requestRichCandidates && !thorough && personalizationMode == nil && dicdataStoreState.canShareStaticConversionResults()
        let resolvedConversionCacheKey: ZenzResolvedConversionCacheKey? = sharesResults
            ? ZenzResolvedConversionCacheKey(
                input: latticeInputData.input,
                convertTarget: latticeInputData.convertTarget,
                convertTargetCursorPosition: zenzInputCursorPosition,
                keyboardLanguage: dicdataStoreState.keyboardLanguage,
                versionDependentConfig: versionDependentConfig,
                prefixConstraint: constraint,
                inferenceLimit: inferenceLimit
            )
            : nil
        if let resolvedConversionCacheKey,
           let cached = zenzaiMemoizationCache.cachedResolvedConversion(
               for: resolvedConversionCacheKey
           ) {
            // 全文経路とは別にprocessResultが参照する先頭辞書ノードだけを復元する。
            // 可変な探索状態を持つラティス本体は共有しない。
            let lattice = Lattice(
                inputCount: latticeInputData.input.count,
                surfaceCount: latticeInputData.convertTarget.count,
                rawNodes: [
                    cached.resultLatticeHead.nodes.map {
                        LatticeNode(data: $0.data, range: $0.range)
                    }
                ]
            )
            let eosNode = LatticeNode.EOSNode
            eosNode.prevs = cached.resultPrevs
            let nextCache = zenzaiCache?.updatingResult(
                for: latticeInputData,
                constraint: cached.prefixConstraint,
                satisfyingCandidate: cached.satisfyingCandidate
            ) ?? ZenzaiCache(
                latticeInputData,
                constraint: cached.prefixConstraint,
                satisfyingCandidate: cached.satisfyingCandidate,
                evaluatedSatisfyingCandidate: cached.satisfyingCandidate
            )
            return (
                eosNode,
                lattice,
                nextCache
            )
        }
        debug("initial constraint", constraint)
        let eosNode = LatticeNode.EOSNode
        var lattice: Lattice = Lattice()
        var latticeIsComplete = true
        var constructedCandidates: [(RegisteredNode, Candidate)] = []
        var insertedCandidates: [(RegisteredNode, Candidate)] = []
        /// Every candidate the model gave a probability to, for choosing the most probable one at the end
        var evaluated: [(node: RegisteredNode, candidate: Candidate, total: Float)] = []
        /// The candidate the model judged last: the current constraint is its correction
        var lastEvaluated: Candidate?
        /// The dictionary's first draft and the model's first correction of it, when there was one
        var firstCorrection: (draft: Candidate, correction: PrefixConstraint)?
        // A thorough conversion runs once, for committing, so it may ask the model more
        var inferenceLimit = thorough ? max(inferenceLimit, 12) : inferenceLimit
        func makeCache(
            constraint: PrefixConstraint,
            satisfyingCandidate: Candidate?,
            evaluatedSatisfyingCandidate: Candidate? = nil
        ) -> ZenzaiCache {
            ZenzaiCache(
                latticeInputData,
                constraint: constraint,
                satisfyingCandidate: satisfyingCandidate,
                evaluatedSatisfyingCandidate: evaluatedSatisfyingCandidate,
                prefixCandidate: prefixCandidate,
                lattice: latticeIsComplete ? lattice : nil
            )
        }
        defer {
            eosNode.prevs = insertedCandidates.map(\.0)
        }
        func noting(_ node: RegisteredNode, _ candidate: Candidate, _ result: CandidateEvaluationResult) {
            // A candidate writing Latin letters the input does not have is a reading written in romaji: never chosen
            // by probability, whatever the model makes of it
            guard !Self.writesLettersNotTyped(candidate.text, input: inputData.convertTarget) else {
                return
            }
            if let likelihood = result.likelihood {
                evaluated.append((node, candidate, likelihood.total))
            }
        }
        /// In a thorough conversion, the most probable of the candidates the model scored, moved to the front of the
        /// results; otherwise `fallback`. A candidate the model corrected token by token is not always the one it finds
        /// most probable as a whole: the dictionary's draft may be, as in a beam search. While typing, the corrected
        /// candidate stands, so the next key goes on from the model's corrections with one inference
        func choosing(_ fallback: Candidate?) -> Candidate? {
            guard thorough, !evaluated.isEmpty else {
                return fallback
            }
            var ranked = evaluated.sorted { $0.total > $1.total }
            if let secondOpinion, cancellation?.isCancelled != true {
                // The second model scores the likeliest few as wholes. Those it prefers to the first model's choice by at
                // least the threshold are weighed against it by A + λ·B; a smaller preference is not heard, as the
                // second model is the weaker one. The context is the conversion model's prompt, shared
                var scored: [(node: RegisteredNode, candidate: Candidate, first: Float, second: Float)] = []
                for item in ranked.prefix(Self.secondOpinionCandidateCount) {
                    let result = secondOpinion.model.candidateEvaluate(
                        convertTarget: inputData.convertTarget,
                        candidates: [item.candidate],
                        requestRichCandidates: false,
                        prefixConstraint: PrefixConstraint([]),
                        personalizationMode: nil,
                        versionDependentConfig: versionDependentConfig,
                        memoizationCache: secondOpinion.memoizationCache
                    )
                    guard let second = result.likelihood?.total else {
                        scored.removeAll()
                        break
                    }
                    scored.append((item.node, item.candidate, item.total, second))
                }
                if let first = scored.first {
                    ZenzaiTrace.log("second opinion " + scored.map { "\($0.candidate.text) (\($0.first) + \($0.second))" }.joined(separator: ", "))
                    // The second model does not decide between letters and Japanese: that is the identification layer's,
                    // and letters written for Japanese are the worst error. It is heard only for candidates with the same
                    // Latin letters as the first model's choice
                    let letters = Self.latinLetters(first.candidate.text)
                    let heard = scored.filter {
                        $0.second - first.second >= secondOpinion.threshold && Self.latinLetters($0.candidate.text) == letters
                    }
                    let best = ([first] + heard).max { ($0.first + secondOpinion.weight * $0.second) < ($1.first + secondOpinion.weight * $1.second) }!
                    if best.candidate.text != first.candidate.text {
                        ranked.removeAll { $0.candidate.text == best.candidate.text }
                        ranked.insert((best.node, best.candidate, best.first), at: 0)
                    }
                }
            }
            let best = ranked[0]
            ZenzaiTrace.log("chosen \(best.candidate.text) among " + evaluated.map { "\($0.candidate.text) (\($0.total))" }.joined(separator: ", "))
            if let at = insertedCandidates.firstIndex(where: { $0.1.text == best.candidate.text }) {
                insertedCandidates.remove(at: at)
            }
            insertedCandidates.insert((best.node, best.candidate), at: 0)
            return best.candidate
        }
        /// The dictionary's best conversion of the whole input under `constraint`, from the lattice built so far
        func searching(_ constraint: PrefixConstraint) -> (node: RegisteredNode, candidate: Candidate)? {
            lattice.resetNodeStates()
            let found = self.kana2lattice_all_with_prefix_constraint(
                latticeInputData,
                N_best: 1,
                constraint: constraint,
                preprocessedLattice: lattice,
                dicdataStoreState: dicdataStoreState
            )
            let candidates = found.result.getCandidateData().map(self.processClauseCandidate)
            guard let best = candidates.indices.max(by: { candidates[$0].value < candidates[$1].value }) else {
                return nil
            }
            return (found.result.prevs[best], candidates[best])
        }
        /// Asks the model about `candidate`, counting the inference. Once the conversion is called off (see `cancellation`),
        /// no inference is left and the candidate passes unasked
        func evaluating(_ candidate: Candidate, constraint: PrefixConstraint, rich: Bool) -> CandidateEvaluationResult {
            if cancellation?.isCancelled == true {
                inferenceLimit = 0
                return .pass(score: 0, alternativeConstraints: [], likelihood: nil)
            }
            inferenceLimit -= 1
            return zenz.candidateEvaluate(
                convertTarget: inputData.convertTarget,
                convertTargetCursorPosition: zenzInputCursorPosition,
                candidates: [candidate],
                requestRichCandidates: rich,
                prefixConstraint: constraint,
                personalizationMode: personalizationMode,
                versionDependentConfig: versionDependentConfig,
                memoizationCache: zenzaiMemoizationCache
            )
        }
        /// Follows the model's corrections from `start` for up to `steps` inferences, noting every candidate it judges:
        /// a plainer run of the loop below, for the other readings a thorough conversion weighs
        func branching(from start: PrefixConstraint, steps: Int) {
            var constraint = start
            var last: Candidate?
            for _ in 0 ..< steps where inferenceLimit > 0 {
                guard let found = searching(constraint) else {
                    guard let last, let accepting = Self.fixingThroughDisagreement(last, with: constraint) else {
                        return
                    }
                    constraint = accepting
                    continue
                }
                if evaluated.contains(where: { $0.candidate.text == found.candidate.text }) {
                    return
                }
                let result = evaluating(found.candidate, constraint: constraint, rich: false)
                ZenzaiTrace.log("branch: \(found.candidate.text) -> \(ZenzaiTrace.describe(result))")
                insertedCandidates.insert(found, at: min(1, insertedCandidates.count))
                noting(found.node, found.candidate, result)
                last = found.candidate
                switch result {
                case .fixRequired(let prefix, _):
                    constraint = Self.normalizedZenzConstraint(prefix, defaultHasEOS: false, ignoreMemoryAndUserDictionary: constraint.ignoreMemoryAndUserDictionary, fixedPrefix: constraint.fixedPrefix, acceptedByteCount: constraint.acceptedByteCount)
                case .wholeResult(let whole):
                    constraint = Self.normalizedZenzConstraint(Array(whole.utf8), defaultHasEOS: true, ignoreMemoryAndUserDictionary: constraint.ignoreMemoryAndUserDictionary, fixedPrefix: constraint.fixedPrefix, acceptedByteCount: constraint.acceptedByteCount)
                case .pass, .error:
                    return
                }
            }
        }
        var draftIteration = 0
        while true {
            let start = Date()
            // 学習・ユーザ辞書・personalizationの影響がなく、入力と制約が完全一致する
            // 初回draftだけを共有する。後続draftは直前の探索状態に依存するため対象外。
            let draftCacheKey: ZenzDraftConversionCacheKey? = if draftIteration == 0,
                                                                 !requestRichCandidates,
                                                                 !thorough,
                                                                 personalizationMode == nil,
                                                                 dicdataStoreState.canShareStaticConversionResults() {
                ZenzDraftConversionCacheKey(
                    input: latticeInputData.input,
                    convertTarget: latticeInputData.convertTarget,
                    convertTargetCursorPosition: zenzInputCursorPosition,
                    keyboardLanguage: dicdataStoreState.keyboardLanguage,
                    versionDependentConfig: versionDependentConfig,
                    prefixConstraint: constraint
                )
            } else {
                nil
            }
            let cachedDraft = draftCacheKey.flatMap {
                zenzaiMemoizationCache.cachedDraftConversion(for: $0)
            }
            let preprocessedLattice: Lattice?
            if cachedDraft != nil {
                preprocessedLattice = nil
            } else if !lattice.isEmpty {
                // 今回の`all_zenzai`の呼び出し内部で使われているキャッシュ（lattice）が存在する場合はそちらを優先する
                lattice.resetNodeStates()
                preprocessedLattice = lattice
            } else {
                // latticeがまだemptyの場合、zenzaiCache側に存在するキャッシュの活用を試みる
                preprocessedLattice = zenzaiCache?.getPreprocessedLattice(
                    for: latticeInputData,
                    kanaKanji: self,
                    dicdataStoreState: dicdataStoreState
                )
            }
            let draftResult: (result: LatticeNode, lattice: Lattice)
            if let cachedDraft {
                let cachedLattice = Lattice(
                    inputCount: latticeInputData.input.count,
                    surfaceCount: latticeInputData.convertTarget.count,
                    rawNodes: [
                        cachedDraft.resultLatticeHead.nodes.map {
                            LatticeNode(data: $0.data, range: $0.range)
                        }
                    ]
                )
                let cachedResult = LatticeNode.EOSNode
                cachedResult.prevs = cachedDraft.resultPrevs
                draftResult = (cachedResult, cachedLattice)
                // processResultが参照する先頭ノードだけを復元しているため、
                // 後続draftのpreprocessed latticeとしては利用できない。
                latticeIsComplete = false
            } else if constraint.isEmpty {
                draftResult = self.kana2lattice_all(
                    latticeInputData,
                    N_best: 2,
                    needTypoCorrection: false,
                    preprocessedLattice: preprocessedLattice,
                    dicdataStoreState: dicdataStoreState
                )
            } else {
                // rich候補を要求しない通常モードでは最良経路しか消費しない。
                // rich候補用の代替制約探索では従来どおり3-bestを保持する。
                // A thorough conversion keeps the best path only, rich or not: the clauses of a thorough conversion shown
                // (rich) are then those of the conversion shown, as the drafts are the same and their scores memoized
                let constrainedNBest = requestRichCandidates && !thorough ? 3 : 1
                draftResult = self.kana2lattice_all_with_prefix_constraint(
                    latticeInputData,
                    N_best: constrainedNBest,
                    constraint: constraint,
                    preprocessedLattice: preprocessedLattice,
                    dicdataStoreState: dicdataStoreState
                )
            }
            if let draftCacheKey, cachedDraft == nil {
                zenzaiMemoizationCache.cacheDraftConversion(
                    ZenzDraftConversion(
                        resultPrevs: draftResult.result.prevs,
                        resultLatticeHead: ZenzResolvedLatticeHead(
                            nodes: draftResult.lattice[
                                index: .bothIndex(inputIndex: 0, surfaceIndex: 0)
                            ].map {
                                ZenzResolvedLatticeNode(data: $0.data, range: $0.range)
                            }
                        )
                    ),
                    for: draftCacheKey
                )
            }
            if lattice.isEmpty {
                // 初回のみ
                lattice = draftResult.lattice
            }
            let candidates = draftResult.result.getCandidateData().map(self.processClauseCandidate)
            constructedCandidates.append(contentsOf: zip(draftResult.result.prevs, candidates))
            var best: (Int, Candidate)?
            for (i, cand) in candidates.enumerated() {
                if let (_, c) = best, cand.value > c.value {
                    best = (i, cand)
                } else if best == nil {
                    best = (i, cand)
                }
            }
            draftIteration += 1
            guard var (index, candidate) = best else {
                debug("best was not found!")
                ZenzaiTrace.log("no candidate satisfies \(constraint)")
                // The dictionary cannot make the model's correction (a word it lacks, a notation it does not form). Then
                // the candidate corrected stands as it is through the word in question, and the model judges the rest
                // after it, instead of the whole candidate being given up
                if let last = lastEvaluated {
                    if let fixed = Self.fixingThroughDisagreement(last, with: constraint) {
                        ZenzaiTrace.log("keeping \(String(decoding: fixed.constraint, as: UTF8.self)) as it is")
                        constraint = fixed
                        continue
                    }
                    // The disagreement is in the last word: the candidate stands as a whole. It is not accepted: while
                    // typing the last word is usually unfinished (保書 for ほしょ while 保障 is typed), and the next key
                    // must let the model correct it
                    let chosen = choosing(last) ?? last
                    let stands = PrefixConstraint(Array(chosen.text.utf8), fixedPrefix: constraint.fixedPrefix)
                    return (eosNode, lattice, makeCache(constraint: stands, satisfyingCandidate: chosen, evaluatedSatisfyingCandidate: chosen))
                }
                // Emptyの場合
                // 制約が満たせない場合は無視する
                return (eosNode, lattice, makeCache(constraint: PrefixConstraint([]), satisfyingCandidate: nil))
            }

            debug("Constrained draft modeling", -start.timeIntervalSinceNow)
            reviewLoop: while true {
                // resultsを更新
                // ここでN-Bestも並び変えていることになる
                insertedCandidates.insert((draftResult.result.prevs[index], candidate), at: 0)
                if inferenceLimit == 0 {
                    debug("inference limit! \(candidate.text) is used for excuse")
                    ZenzaiTrace.log("inference limit reached; using \(candidate.text)")
                    // When inference occurs more than maximum times, then just return result at this point: the latest
                    // draft, which satisfies every correction so far, though the model has not scored it
                    return (eosNode, lattice, makeCache(constraint: constraint, satisfyingCandidate: candidate))
                }
                if defersEvaluationForPendingInput {
                    // ローマ字表で未確定のsuffixは、次のキーでかなへ置換される。
                    // モデルが未確定ASCIIを評価しても結果を再利用できないため、
                    // かな列が確定するまで評価を省略する。未評価のdraftは制約へ
                    // 昇格させず、現在の入力にも適用できた直前のLM承認候補だけを
                    // stable prefixとして引き継ぐ。
                    let evaluatedCandidate = constraint.isEmpty
                        ? nil
                        : zenzaiCache?.evaluatedSatisfyingCandidate
                    return (
                        eosNode,
                        lattice,
                        makeCache(
                            constraint: constraint,
                            satisfyingCandidate: evaluatedCandidate,
                            evaluatedSatisfyingCandidate: evaluatedCandidate
                        )
                    )
                }
                let reviewResult = evaluating(candidate, constraint: constraint, rich: requestRichCandidates || thorough)
                ZenzaiTrace.log("draft \(draftIteration): \(candidate.text) (value \(candidate.value)) -> \(ZenzaiTrace.describe(reviewResult))")
                noting(draftResult.result.prevs[index], candidate, reviewResult)
                lastEvaluated = candidate
                if draftIteration == 1, firstCorrection == nil, case .fixRequired(let prefix, _) = reviewResult {
                    firstCorrection = (candidate, Self.normalizedZenzConstraint(prefix, defaultHasEOS: false, ignoreMemoryAndUserDictionary: constraint.ignoreMemoryAndUserDictionary, fixedPrefix: constraint.fixedPrefix, acceptedByteCount: constraint.acceptedByteCount))
                }
                let trailing = reviewResult.likelihood?.trailing
                let nextAction = self.review(
                    candidateIndex: index,
                    candidates: candidates,
                    reviewResult: reviewResult,
                    constraint: &constraint
                )
                switch nextAction {
                case .return(let constraint, let alternativeConstraints, let satisfied):
                    var alternatives: [(RegisteredNode, Candidate)] = []
                    defer { _ = alternatives }
                    if requestRichCandidates || thorough {
                        // alternativeConstraintsに従い、insertedCandidatesにデータを追加する
                        for alternativeConstraint in alternativeConstraints.reversed() where alternativeConstraint.probabilityRatio > 0.25 {
                            let normalizedAlternativeConstraint = Self.normalizedZenzConstraint(
                                alternativeConstraint.prefixConstraint,
                                defaultHasEOS: false,
                                ignoreMemoryAndUserDictionary: false
                            )
                            // constructed candidatesのうちalternativeConstraint.prefixConstraintを満たすものを列挙する
                            let mostLiklyCandidate = constructedCandidates.filter {
                                self.candidate($0.1, satisfies: normalizedAlternativeConstraint)
                            }.max {
                                $0.1.value < $1.1.value
                            }
                            if let mostLiklyCandidate {
                                // 0番目は最良候補
                                insertedCandidates.insert(mostLiklyCandidate, at: 1)
                                alternatives.append(mostLiklyCandidate)
                            } else if alternativeConstraint.probabilityRatio > 0.5, let found = searching(normalizedAlternativeConstraint) {
                                // 十分に高い確率の場合、変換器を実際に呼び出して候補を作ってもらう
                                insertedCandidates.insert(found, at: 1)
                                alternatives.append(found)
                            }
                        }
                    }
                    if satisfied {
                        if thorough {
                            // The word the model would go on with after the candidate, when it does not end there: the
                            // dictionary may have the candidate ending with that word (初 → 初め)
                            if inferenceLimit > 0, let trailing,
                               let probe = searching(PrefixConstraint(Array(candidate.text.utf8) + trailing, fixedPrefix: constraint.fixedPrefix)),
                               !evaluated.contains(where: { $0.candidate.text == probe.candidate.text }) {
                                let result = evaluating(probe.candidate, constraint: constraint, rich: false)
                                ZenzaiTrace.log("going on with '\(String(decoding: trailing, as: UTF8.self))': \(probe.candidate.text) -> \(ZenzaiTrace.describe(result))")
                                insertedCandidates.insert(probe, at: 1)
                                noting(probe.node, probe.candidate, result)
                            }
                            // The dictionary's draft with the word the model corrected first kept as it is, and the model's
                            // corrections of what follows (高官…ようご: the model corrected 高官 first, and 用語 was never tried)
                            if let (draft, correction) = firstCorrection, let accepting = Self.fixingThroughDisagreement(draft, with: correction) {
                                branching(from: accepting, steps: 3)
                            }
                            // The readings the model found nearly as likely at some token, with its corrections after them
                            for alternativeConstraint in alternativeConstraints.prefix(3) where alternativeConstraint.probabilityRatio > 0.2 {
                                branching(
                                    from: Self.normalizedZenzConstraint(alternativeConstraint.prefixConstraint, defaultHasEOS: false, ignoreMemoryAndUserDictionary: false, fixedPrefix: constraint.fixedPrefix),
                                    steps: 3
                                )
                            }
                            // The conversion shown while typing, when starting over did not come back to it
                            if inferenceLimit > 0, let shown = zenzaiCache?.evaluatedSatisfyingCandidate,
                               shown.data.map(\.ruby).joined() == latticeInputData.convertTarget.toKatakana(),
                               !evaluated.contains(where: { $0.candidate.text == shown.text }),
                               let found = searching(PrefixConstraint(Array(shown.text.utf8), hasEOS: true)) {
                                let result = evaluating(found.candidate, constraint: constraint, rich: false)
                                ZenzaiTrace.log("shown while typing: \(found.candidate.text) -> \(ZenzaiTrace.describe(result))")
                                insertedCandidates.insert(found, at: 1)
                                noting(found.node, found.candidate, result)
                            }
                        }
                        let chosen = choosing(candidate) ?? candidate
                        let chosenConstraint = chosen.text == candidate.text
                            ? constraint
                            : PrefixConstraint(Array(chosen.text.utf8), fixedPrefix: constraint.fixedPrefix)
                        if let resolvedConversionCacheKey,
                           insertedCandidates.allSatisfy({
                               $0.1.data.allSatisfy {
                                   $0.metadata.isDisjoint(
                                       with: [.isLearned, .isFromUserDictionary]
                                   )
                               }
                           }) {
                            zenzaiMemoizationCache.cacheResolvedConversion(
                                ZenzResolvedConversion(
                                    resultPrevs: insertedCandidates.map(\.0),
                                    resultLatticeHead: ZenzResolvedLatticeHead(
                                        nodes: lattice[
                                            index: .bothIndex(inputIndex: 0, surfaceIndex: 0)
                                        ].map {
                                            ZenzResolvedLatticeNode(
                                                data: $0.data,
                                                range: $0.range
                                            )
                                        }
                                    ),
                                    prefixConstraint: chosenConstraint,
                                    satisfyingCandidate: chosen
                                ),
                                for: resolvedConversionCacheKey
                            )
                        }
                        return (
                            eosNode,
                            lattice,
                            makeCache(
                                constraint: chosenConstraint,
                                satisfyingCandidate: chosen,
                                evaluatedSatisfyingCandidate: chosen
                            )
                        )
                    } else {
                        ZenzaiTrace.log("giving up; showing \(candidate.text)")
                        _ = choosing(nil)
                        return (eosNode, lattice, makeCache(constraint: constraint, satisfyingCandidate: nil))
                    }
                case .continue:
                    if !latticeIsComplete {
                        lattice = Lattice()
                        latticeIsComplete = true
                    }
                    break reviewLoop
                case .retry(let candidateIndex):
                    ZenzaiTrace.log("retry with \(candidates[candidateIndex].text)")
                    index = candidateIndex
                    candidate = candidates[candidateIndex]
                }
            }
        }
    }

    /// The runs of Latin letters in `text`, lowercased, apart from letters right after a number, which write the unit the
    /// number was read with (50cm): the same exemption as `writesLettersNotTyped`
    static func latinLetters(_ text: String) -> [String] {
        var runs: [String] = []
        var run = ""
        var afterNumber = false
        var runIsUnit = false
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic {
                if run.isEmpty {
                    runIsUnit = afterNumber
                }
                run.unicodeScalars.append(scalar)
            } else {
                if !run.isEmpty, !runIsUnit {
                    runs.append(run)
                }
                run = ""
                afterNumber = scalar.properties.numericType != nil
            }
        }
        if !run.isEmpty, !runIsUnit {
            runs.append(run)
        }
        return runs
    }

    /// Whether `text` has Latin letters that `input` (the reading typed, with any Latin words as typed) does not, apart
    /// from letters right after a number, which write the unit the number was read with (50cm for ゴジュウセンチメートル)
    static func writesLettersNotTyped(_ text: String, input: String) -> Bool {
        let typed = Set(input.lowercased().unicodeScalars.filter(\.isASCII))
        var afterNumber = false
        var runIsUnit = false
        var inRun = false
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic {
                if !inRun {
                    runIsUnit = afterNumber
                    inRun = true
                }
                if !runIsUnit, !typed.contains(scalar) {
                    return true
                }
            } else {
                inRun = false
                afterNumber = scalar.properties.numericType != nil
            }
        }
        return false
    }

    /// A constraint that keeps `candidate` as it is through the word where the model's `correction` of it departs from
    /// it, so the model judges only what follows: for when the dictionary cannot make the correction. Nil when nothing
    /// follows that word
    static func fixingThroughDisagreement(_ candidate: Candidate, with correction: PrefixConstraint) -> PrefixConstraint? {
        guard candidate.data.map(\.word).joined() == candidate.text else {
            return nil
        }
        let text = Array(candidate.text.utf8)
        let agreeing = zip(text, correction.constraint).prefix { $0 == $1 }.count
        var byteCount = 0
        var rubyCount = 0
        for element in candidate.data {
            byteCount += element.word.utf8.count
            rubyCount += element.ruby.count
            if byteCount > agreeing {
                break
            }
        }
        let alreadyAccepted = max(correction.acceptedByteCount, correction.fixedPrefix?.byteCount ?? 0)
        guard alreadyAccepted < byteCount, byteCount < text.count else {
            return nil
        }
        _ = rubyCount
        return PrefixConstraint(
            Array(text.prefix(byteCount)),
            ignoreMemoryAndUserDictionary: correction.ignoreMemoryAndUserDictionary,
            fixedPrefix: correction.fixedPrefix,
            acceptedByteCount: byteCount
        )
    }

    private enum NextAction {
        case `return`(constraint: PrefixConstraint, alternativeConstraints: [CandidateEvaluationResult.AlternativeConstraint], satisfied: Bool)
        case `continue`
        case `retry`(candidateIndex: Int)
    }

    static func zenzaiLatticeInputData(for inputData: ComposingText) -> ComposingText {
        inputData.isAtEndIndex ? inputData : inputData.prefixToCursorPosition()
    }

    static func zenzaiInputCursorPosition(for inputData: ComposingText) -> Int? {
        inputData.isAtEndIndex ? nil : inputData.convertTargetCursorPosition
    }

    private func review(
        candidateIndex: Int,
        candidates: [Candidate],
        reviewResult: consuming CandidateEvaluationResult,
        constraint: inout PrefixConstraint
    ) -> NextAction {
        switch reviewResult {
        case .error:
            // 何らかのエラーが発生
            debug("error")
            return .return(constraint: constraint, alternativeConstraints: [], satisfied: false)
        case .pass(let score, let alternativeConstraints, _):
            // 合格
            debug("passed:", score)
            return .return(constraint: constraint, alternativeConstraints: alternativeConstraints, satisfied: true)
        case .fixRequired(let prefixConstraint, _):
            let newConstraint = Self.normalizedZenzConstraint(
                prefixConstraint,
                defaultHasEOS: false,
                ignoreMemoryAndUserDictionary: constraint.ignoreMemoryAndUserDictionary,
                fixedPrefix: constraint.fixedPrefix,
                acceptedByteCount: constraint.acceptedByteCount
            )
            if constraint == newConstraint {
                if !constraint.ignoreMemoryAndUserDictionary, candidates[candidateIndex].data.contains(where: { !$0.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary])}) {
                    // `ignoreMemoryAndUserDictionary`でない場合、学習候補がモデルにリジェクトされた可能性を検討する
                    debug("same constraint (fixRequired), but retry without memory and user dictionary:", newConstraint)
                    constraint.ignoreMemoryAndUserDictionary = true
                    for (i, candidate) in candidates.indexed() where i != candidateIndex {
                        if self.candidate(candidate, satisfies: newConstraint) && self.heuristicRetryValidation(candidate.text) {
                            debug("found \(candidate.text) as another retry")
                            return .retry(candidateIndex: i)
                        }
                    }
                    return .continue
                } else {
                    // それ以外の場合で同じ制約が2回連続で出てきたら諦める
                    debug("same constraint (fixRequired):", newConstraint)
                    ZenzaiTrace.log("same constraint again (fix required): \(newConstraint)")
                    return .return(constraint: PrefixConstraint([]), alternativeConstraints: [], satisfied: false)
                }
            }
            // 制約が得られたので、更新する
            let isIncrementalUpdate = newConstraint.constraint.hasPrefix(constraint.constraint)
            constraint = newConstraint
            debug("update constraint:", constraint)
            if isIncrementalUpdate {
                // もし制約を満たす候補があるならそれを使って再レビューチャレンジを戦うことで、推論を減らせる
                // この処理の正当性は、prefix constraintが漸進的に更新され、candidatesの構築時に可能な候補がすべて確認されたことに由来する
                // このため、学習候補などが最終ドラフトとして採択され、prefix constraintが漸進的更新になっていない場合（!isIncrementalUpdate）この処理は行わない
                for (i, candidate) in candidates.indexed() where i != candidateIndex {
                    if self.candidate(candidate, satisfies: newConstraint) && self.heuristicRetryValidation(candidate.text) {
                        debug("found \(candidate.text) as another retry")
                        return .retry(candidateIndex: i)
                    }
                }
            }
            return .continue
        case .wholeResult(let wholeConstraint):
            let newConstraint = Self.normalizedZenzConstraint(
                Array(wholeConstraint.utf8),
                defaultHasEOS: true,
                ignoreMemoryAndUserDictionary: constraint.ignoreMemoryAndUserDictionary,
                fixedPrefix: constraint.fixedPrefix,
                acceptedByteCount: constraint.acceptedByteCount
            )
            // 同じ制約が2回連続で出てきたら諦める
            if constraint == newConstraint {
                if !constraint.ignoreMemoryAndUserDictionary, candidates[candidateIndex].data.contains(where: { !$0.metadata.isDisjoint(with: [.isLearned, .isFromUserDictionary])}) {
                    // `ignoreMemoryAndUserDictionary`でない場合、学習候補がモデルにリジェクトされた可能性を検討する
                    debug("same constraint (wholeResult), but retry without memory and user dictionary:", constraint)
                    constraint.ignoreMemoryAndUserDictionary = true
                    for (i, candidate) in candidates.indexed() where i != candidateIndex {
                        if self.candidate(candidate, satisfies: newConstraint) && self.heuristicRetryValidation(candidate.text) {
                            debug("found \(candidate.text) as another retry")
                            return .retry(candidateIndex: i)
                        }
                    }
                    return .continue
                } else {
                    // それ以外の場合で同じ制約が2回連続で出てきたら諦める
                    debug("same constraint (wholeResult):", constraint)
                    ZenzaiTrace.log("same constraint again (whole result): \(constraint)")
                    return .return(constraint: PrefixConstraint([]), alternativeConstraints: [], satisfied: false)
                }
            }
            // 制約が得られたので、更新する
            debug("update whole constraint:", wholeConstraint)
            let isIncrementalUpdate = newConstraint.constraint.hasPrefix(constraint.constraint)
            constraint = newConstraint
            if isIncrementalUpdate {
                // もし制約を満たす候補があるならそれを使って再レビューチャレンジを戦うことで、推論を減らせる
                // 上記と同様に、prefix constraintが漸進的更新になっていない場合（!isIncrementalUpdate）この処理は行わない
                for (i, candidate) in candidates.indexed() where i != candidateIndex {
                    if self.candidate(candidate, satisfies: newConstraint) && self.heuristicRetryValidation(candidate.text) {
                        debug("found \(candidate.text) as another retry")
                        return .retry(candidateIndex: i)
                    }
                }
            }
            return .continue
        }
    }

    static func normalizedZenzConstraint(
        _ constraintBytes: [UInt8],
        defaultHasEOS: Bool,
        ignoreMemoryAndUserDictionary: Bool,
        fixedPrefix: PrefixConstraint.FixedPrefix? = nil,
        acceptedByteCount: Int = 0
    ) -> PrefixConstraint {
        // fixedPrefixの byte 数をそのまま引き継げるのは、ZenzCandidateEvaluator.evaluate が結果の先頭に固定された表記を戻すため
        if let prefix = self.prefixBeforeAlignmentSeparator(in: constraintBytes) {
            return PrefixConstraint(prefix, hasEOS: true, ignoreMemoryAndUserDictionary: ignoreMemoryAndUserDictionary, fixedPrefix: fixedPrefix, acceptedByteCount: acceptedByteCount)
        }
        return PrefixConstraint(constraintBytes, hasEOS: defaultHasEOS, ignoreMemoryAndUserDictionary: ignoreMemoryAndUserDictionary, fixedPrefix: fixedPrefix, acceptedByteCount: acceptedByteCount)
    }

    private static func prefixBeforeAlignmentSeparator(in bytes: [UInt8]) -> [UInt8]? {
        let separator = Array(ZenzPromptBuilder.alignmentSeparator.utf8)
        guard bytes.count >= separator.count else {
            return nil
        }
        for index in 0 ... (bytes.count - separator.count) {
            if bytes[index ..< index + separator.count].elementsEqual(separator) {
                return Array(bytes[..<index])
            }
        }
        return nil
    }

    private func candidate(_ candidate: Candidate, satisfies constraint: PrefixConstraint) -> Bool {
        if constraint.hasEOS {
            return candidate.text.utf8.elementsEqual(constraint.constraint)
        } else {
            return candidate.text.utf8.hasPrefix(constraint.constraint)
        }
    }

    /// リトライの候補に対して恣意的なバリデーションを実施する
    private func heuristicRetryValidation(_ text: String) -> Bool {
        // 合成濁点・半濁点
        if text.unicodeScalars.contains("\u{3099}") || text.unicodeScalars.contains("\u{309A}") {
            return false
        }
        return true
    }
}
