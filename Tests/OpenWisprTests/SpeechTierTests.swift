import Foundation
import XCTest
@testable import OpenWisprLib

final class SpeechTierTests: XCTestCase {
    func testTierIgnoresEnglishAndQuantizationSuffixes() {
        XCTAssertEqual(SpeechTier.tier(for: "tiny.en"), .tiny)
        XCTAssertEqual(SpeechTier.tier(for: "tiny"), .tiny)
        XCTAssertEqual(SpeechTier.tier(for: "base.en-q5_1"), .base)
        XCTAssertEqual(SpeechTier.tier(for: "small.en-q5_1"), .small)
        XCTAssertEqual(SpeechTier.tier(for: "small"), .small)
    }

    func testModelsOutsideTheThreeSizesAreNotTiers() {
        XCTAssertNil(SpeechTier.tier(for: "medium.en"))
        XCTAssertNil(SpeechTier.tier(for: "large-v3"))
        XCTAssertNil(SpeechTier.tier(for: "large"))
        XCTAssertNil(SpeechTier.tier(for: "smallish"))
    }

    func testEnglishGetsTheEnglishOnlyModelAndOtherLanguagesTheMultilingualOne() {
        XCTAssertEqual(SpeechTier.base.modelName(language: "en"), "base.en")
        XCTAssertEqual(SpeechTier.base.modelName(language: "fr"), "base")
        XCTAssertEqual(SpeechTier.small.modelName(language: "auto"), "small")
    }

    func testEveryTierMapsToASupportedModel() {
        for tier in SpeechTier.allCases {
            for language in ["en", "fr", "auto"] {
                XCTAssertTrue(Config.supportedModels.contains(tier.modelName(language: language)))
            }
        }
    }

    func testChangingLanguageKeepsTheSizeAndSwapsTheModelFamily() {
        XCTAssertEqual(Config.modelSize(for: "fr", keeping: "base.en"), "base")
        XCTAssertEqual(Config.modelSize(for: "en", keeping: "base"), "base.en")
        XCTAssertEqual(Config.modelSize(for: "auto", keeping: "small.en-q5_1"), "small")
        XCTAssertEqual(Config.modelSize(for: "fr", keeping: "medium.en"), "medium")
        XCTAssertEqual(Config.modelSize(for: "en", keeping: "medium"), "medium.en")
        XCTAssertEqual(Config.modelSize(for: "en", keeping: "large-v3"), "large-v3")
    }
}

final class DipLevelTests: XCTestCase {
    private func config(_ extra: String) throws -> Config {
        try Config.decode(from: Data(#"{"modelSize":"base.en","language":"en"\#(extra)}"#.utf8))
    }

    func testSliderIndexIsClamped() {
        XCTAssertEqual(DipLevel(index: -1), .light)
        XCTAssertEqual(DipLevel(index: 1), .medium)
        XCTAssertEqual(DipLevel(index: 9), .strong)
        XCTAssertEqual(DipLevel.allCases.map(\.index), [0, 1, 2])
    }

    func testDefaultsToMediumAndDippingOff() throws {
        let config = try config("")
        XCTAssertEqual(config.effectiveDipLevel, .medium)
        XCTAssertFalse(config.usesVoiceProcessing)
    }

    func testReadsAndRoundTripsTheLevel() throws {
        XCTAssertEqual(try config(#","dipLevel":"strong""#).effectiveDipLevel, .strong)
        XCTAssertEqual(try config(#","dipLevel":"bogus""#).effectiveDipLevel, .medium)
        var config = try config("")
        config.dipLevel = "light"
        let decoded = try Config.decode(from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.effectiveDipLevel, .light)
    }
}

final class OverlayConfigTests: XCTestCase {
    func testRecordingOverlayIsOnUnlessTurnedOff() throws {
        let on = try Config.decode(from: Data(#"{"modelSize":"base.en","language":"en"}"#.utf8))
        XCTAssertTrue(on.usesOverlay)
        let off = try Config.decode(from: Data(#"{"modelSize":"base.en","language":"en","overlay":false}"#.utf8))
        XCTAssertFalse(off.usesOverlay)
    }

    func testOverlayPositionDefaultsToTopAndMapsToTheScreenGrid() throws {
        let base = #"{"modelSize":"base.en","language":"en""#
        XCTAssertEqual(try Config.decode(from: Data((base + "}").utf8)).effectiveOverlayPosition, .top)
        XCTAssertEqual(try Config.decode(from: Data((base + #","overlayPosition":"bottom-right"}"#).utf8)).effectiveOverlayPosition, .bottomRight)
        XCTAssertEqual(try Config.decode(from: Data((base + #","overlayPosition":"nowhere"}"#).utf8)).effectiveOverlayPosition, .top)
        XCTAssertEqual(OverlayPosition.allCases.count, 9)
        XCTAssertEqual(OverlayPosition.topLeft.column, -1)
        XCTAssertEqual(OverlayPosition.topLeft.row, -1)
        XCTAssertEqual(OverlayPosition.center.column, 0)
        XCTAssertEqual(OverlayPosition.bottomRight.row, 1)
    }
}
