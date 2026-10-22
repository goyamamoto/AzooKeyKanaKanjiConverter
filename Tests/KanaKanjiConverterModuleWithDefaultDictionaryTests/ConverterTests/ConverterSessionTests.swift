import Foundation
@testable import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

final class ConverterSessionTests: XCTestCase {
    func testStopCompositionOnlyResetsActiveSession() throws {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let firstSession = converter.createSession()
        let secondSession = converter.createSession()

        try converter.withSession(firstSession) {
            converter.stopComposition()
        }

        XCTAssertNoThrow(
            try converter.withSession(secondSession) {
                var composingText = ComposingText()
                composingText.insertAtCursorPosition("あずーきー", inputStyle: .direct)
                _ = converter.requestCandidates(composingText, options: requestOptions())
            }
        )
    }

    func testRemovedSessionCannotBeSelected() throws {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let removedSession = converter.createSession()
        let remainingSession = converter.createSession()

        converter.removeSession(removedSession)

        XCTAssertThrowsError(try converter.withSession(removedSession) {}) { error in
            XCTAssertEqual(
                error as? KanaKanjiConverter.ConversionSessionError,
                .unknownSession(removedSession)
            )
        }
        XCTAssertNoThrow(try converter.withSession(remainingSession) {})
    }

    func testNestedSessionSelectionRestoresOuterSession() throws {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let outerSession = converter.createSession()
        let innerSession = converter.createSession()

        try converter.withSession(outerSession) {
            try converter.withSession(innerSession) {
                converter.stopComposition()
            }
            converter.stopComposition()
        }

        XCTAssertNoThrow(try converter.withSession(outerSession) {})
        XCTAssertNoThrow(try converter.withSession(innerSession) {})
    }

    func testConversionInCopiedSessionLeavesOriginal() throws {
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let session = converter.createSession()
        let control = converter.createSession()
        func convert(_ text: String) -> [String] {
            var composingText = ComposingText()
            composingText.insertAtCursorPosition(text, inputStyle: .direct)
            return converter.requestCandidates(composingText, options: requestOptions()).mainResults.prefix(5).map(\.text)
        }
        for id in [session, control] {
            _ = try converter.withSession(id) { convert("かんじへんかん") }
        }
        let copy = try converter.copySession(session)
        _ = try converter.withSession(copy) { convert("まったくちがうにゅうりょく") }
        converter.removeSession(copy)

        let afterCopy = try converter.withSession(session) { convert("かんじへんかんは") }
        let withoutCopy = try converter.withSession(control) { convert("かんじへんかんは") }
        XCTAssertEqual(afterCopy, withoutCopy)
        XCTAssertThrowsError(try converter.withSession(copy) {})
        XCTAssertThrowsError(try converter.copySession(copy))
    }

    private func requestOptions() -> ConvertRequestOptions {
        ConvertRequestOptions(
            N_best: 10,
            requireJapanesePrediction: .disabled,
            requireEnglishPrediction: .disabled,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: true,
            fullWidthRomanCandidate: false,
            halfWidthKanaCandidate: false,
            learningType: .nothing,
            maxMemoryCount: 0,
            shouldResetMemory: false,
            memoryDirectoryURL: URL(fileURLWithPath: ""),
            sharedContainerURL: URL(fileURLWithPath: ""),
            textReplacer: .empty,
            specialCandidateProviders: [],
            typoCorrectionMode: .disabled,
            metadata: nil
        )
    }
}
