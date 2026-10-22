#if Zenzai || ZenzaiCPU
import llama
#endif
@testable import KanaKanjiConverterModule
import XCTest

final class ZenzAttentionPrecisionTests: XCTestCase {
    func testOnlyF32InTheMetadataAsksForSinglePrecision() {
        XCTAssertEqual(ZenzAttentionPrecision(metadataValue: "f32"), .single)
        XCTAssertEqual(ZenzAttentionPrecision(metadataValue: "f16"), .half)
        XCTAssertEqual(ZenzAttentionPrecision(metadataValue: nil), .half)
    }

    #if Zenzai || ZenzaiCPU
    func testSinglePrecisionTurnsFlashAttentionOff() {
        XCTAssertTrue(ZenzContext.ctx_params(attentionPrecision: .half).flash_attn)
        XCTAssertFalse(ZenzContext.ctx_params(attentionPrecision: .single).flash_attn)
    }
    #endif
}
