import Foundation
@testable import KanaKanjiConverterModule
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

/// 学習の対象にしない語（`DicdataElementMetadata.isNotLearningTarget`）が、単独でも、前後の語と組み合わせても、確定を
/// またいでも学習に入らないことを確かめる
final class LearningTargetTests: XCTestCase {
    private func requestOptions(memoryDirectoryURL: URL) -> ConvertRequestOptions {
        .init(
            N_best: 10,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: true,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .inputAndOutput,
            maxMemoryCount: 100,
            shouldResetMemory: false,
            memoryDirectoryURL: memoryDirectoryURL,
            sharedContainerURL: URL(fileURLWithPath: ""),
            textReplacer: .empty,
            specialCandidateProviders: [],
            metadata: nil
        )
    }

    private func freshMemoryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("learning-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `reading`の変換候補に含まれる、学習から来た語の表記
    private func learnedWords(for reading: String, converter: KanaKanjiConverter, options: ConvertRequestOptions) -> [String] {
        converter.stopComposition()
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(reading, inputStyle: .direct)
        let results = converter.requestCandidates(composingText, options: options)
        return results.mainResults.flatMap { candidate in
            candidate.data.filter { $0.metadata.contains(.isLearned) }.map(\.word)
        }
    }

    private func element(_ word: String, _ ruby: String, cid: Int = CIDData.一般名詞.cid, learned: Bool = true) -> DicdataElement {
        DicdataElement(word: word, ruby: ruby, cid: cid, mid: MIDData.一般.mid, value: -5, metadata: learned ? .empty : .isNotLearningTarget)
    }

    func testWordNotToLearnIsNotMemorizedAloneNorWithItsNeighbours() throws {
        let memory = try freshMemoryDirectory()
        defer { try? FileManager.default.removeItem(at: memory) }
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let options = self.requestOptions(memoryDirectoryURL: memory)
        converter.updateLearningConfig(LearningConfig(learningType: .inputAndOutput, maxMemoryCount: 100, memoryURL: memory))

        // きょうは + イイ (not to learn) + てんき + です, committed at once
        let candidate = Candidate(
            text: "今日はイイ天気です",
            value: -20,
            composingCount: .inputCount(11),
            lastMid: MIDData.一般.mid,
            data: [
                element("今日", "キョウ"),
                element("は", "ハ", cid: CIDData.係助詞ハ.cid),
                element("イイ", "イイ", cid: CIDData.固有名詞.cid, learned: false),
                element("天気", "テンキ"),
                element("です", "デス", cid: CIDData.助動詞デス基本形.cid)
            ]
        )
        converter.updateLearningData(candidate)

        XCTAssertFalse(self.learnedWords(for: "いい", converter: converter, options: options).contains("イイ"))
        // The words around it are learned, each on its side of the cut
        XCTAssertTrue(self.learnedWords(for: "きょう", converter: converter, options: options).contains("今日"))
        XCTAssertTrue(self.learnedWords(for: "てんき", converter: converter, options: options).contains("天気"))
        // Not as one phrase across the cut, nor as a clause pair with it
        XCTAssertFalse(self.learnedWords(for: "きょうはいいてんきです", converter: converter, options: options).contains("今日はイイ天気です"))
        XCTAssertTrue(self.learnedWords(for: "きょうはいいてんき", converter: converter, options: options).allSatisfy { !$0.contains("イイ") })
    }

    func testWordNotToLearnDoesNotBecomeThePreviousWordOfTheNextCommit() throws {
        let memory = try freshMemoryDirectory()
        defer { try? FileManager.default.removeItem(at: memory) }
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let options = self.requestOptions(memoryDirectoryURL: memory)
        converter.updateLearningConfig(LearningConfig(learningType: .inputAndOutput, maxMemoryCount: 100, memoryURL: memory))

        // イイ (not to learn) committed on its own, then てんき: the second learns without the first as its previous word
        converter.updateLearningData(Candidate(
            text: "イイ",
            value: -5,
            composingCount: .inputCount(2),
            lastMid: MIDData.一般.mid,
            data: [element("イイ", "イイ", cid: CIDData.固有名詞.cid, learned: false)]
        ))
        converter.updateLearningData(Candidate(
            text: "天気",
            value: -5,
            composingCount: .inputCount(3),
            lastMid: MIDData.一般.mid,
            data: [element("天気", "テンキ")]
        ))

        XCTAssertFalse(self.learnedWords(for: "いい", converter: converter, options: options).contains("イイ"))
        XCTAssertTrue(self.learnedWords(for: "いいてんき", converter: converter, options: options).allSatisfy { !$0.contains("イイ") })
        XCTAssertTrue(self.learnedWords(for: "てんき", converter: converter, options: options).contains("天気"))
    }
}
