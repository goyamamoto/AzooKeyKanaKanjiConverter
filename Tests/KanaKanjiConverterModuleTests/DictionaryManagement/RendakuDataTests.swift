@testable import KanaKanjiConverterModule
import XCTest

final class RendakuDataTests: XCTestCase {
    /// Words the dictionary shows voiced as compound latter elements qualify (山寺, 先駆け, 花火); words it never shows voiced do
    /// not, however common (記事, 冬)
    func testLatterElements() {
        XCTAssertTrue(RendakuData.latterElements.contains("寺\tテラ"))
        XCTAssertTrue(RendakuData.latterElements.contains("駆け\tカケ"))
        XCTAssertTrue(RendakuData.latterElements.contains("火\tヒ"))
        XCTAssertFalse(RendakuData.latterElements.contains("記事\tキジ"))
        XCTAssertFalse(RendakuData.latterElements.contains("冬\tフユ"))
    }

    /// Every line is a word with a kanji, a tab and a katakana reading whose first kana can be voiced
    func testTableShape() {
        for line in RendakuData.latterElements {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            XCTAssertEqual(fields.count, 2, line)
            guard fields.count == 2, let first = fields[1].first else {
                continue
            }
            XCTAssertNotNil(DicdataStore.voicelessOf.values.first { $0 == first }, line)
            XCTAssertTrue(fields[1].unicodeScalars.allSatisfy { (0x30A0 ... 0x30FF).contains($0.value) }, line)
            XCTAssertFalse(DicdataStore.isWrittenInKana(String(fields[0])), line)
        }
    }
}
