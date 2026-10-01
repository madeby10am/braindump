import XCTest
@testable import OpenWisprLib

final class TranscriberTests: XCTestCase {

    func testArgumentsIncludeWhisperPromptAsSingleFollowingArgument() throws {
        let prompt = "  Use punctuation, keep product names like OpenWispr.  "
        let transcriber = Transcriber(
            modelSize: "base.en",
            language: "en",
            whisperPrompt: prompt
        )
        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        let promptFlagIndex = try XCTUnwrap(args.firstIndex(of: "--prompt"))
        XCTAssertEqual(args[promptFlagIndex + 1], prompt)
        XCTAssertEqual(args.filter { $0 == prompt }.count, 1)
    }

    func testArgumentsDisableCrossWindowContext() throws {
        let transcriber = Transcriber(modelSize: "base.en", language: "en")
        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        let flagIndex = try XCTUnwrap(args.firstIndex(of: "-mc"))
        XCTAssertEqual(args[flagIndex + 1], "0")
    }

    func testArgumentsUseSingleNoTimestampsFlag() {
        let transcriber = Transcriber(modelSize: "base.en", language: "en")
        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        XCTAssertTrue(args.contains("-nt"))
        XCTAssertFalse(args.contains("--no-timestamps"))
    }

    func testArgumentsOmitNilWhisperPrompt() {
        let transcriber = Transcriber(modelSize: "base.en", language: "en")
        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        XCTAssertFalse(args.contains("--prompt"))
    }

    func testArgumentsOmitWhitespaceOnlyWhisperPrompt() {
        let transcriber = Transcriber(
            modelSize: "base.en",
            language: "en",
            whisperPrompt: " \n\t "
        )
        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        XCTAssertFalse(args.contains("--prompt"))
    }

    func testArgumentsKeepSuppressRegexWhenSpokenPunctuationUsesPrompt() throws {
        let prompt = "Use punctuation and short sentences."
        let transcriber = Transcriber(
            modelSize: "base.en",
            language: "en",
            whisperPrompt: prompt
        )
        transcriber.spokenPunctuation = true

        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        let promptFlagIndex = try XCTUnwrap(args.firstIndex(of: "--prompt"))
        XCTAssertEqual(args[promptFlagIndex + 1], prompt)

        let suppressFlagIndex = try XCTUnwrap(args.firstIndex(of: "--suppress-regex"))
        XCTAssertEqual(args[suppressFlagIndex + 1], "[,\\.\\?!;:\\-—]")
    }

    func testBlankAudioMarker() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO]"), "")
    }

    func testBlankAudioWithWhitespace() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("  [BLANK_AUDIO]  "), "")
    }

    func testMultipleMarkers() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] [silence]"), "")
    }

    func testParenthesizedMarker() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("(BLANK_AUDIO)"), "")
    }

    func testNonSpeechEventMarkers() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[Music] [Applause]"), "")
    }

    func testMarkerMixedWithText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello [BLANK_AUDIO] world"), "hello world")
    }

    func testMarkerAtStartOfText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] hello"), "hello")
    }

    func testMarkerAtEndOfText() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello [BLANK_AUDIO]"), "hello")
    }

    func testNormalTextUnchanged() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("hello world"), "hello world")
    }

    func testEmptyString() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers(""), "")
    }

    func testUnknownBracketsPreserved() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("see [1] and (later)"), "see [1] and (later)")
    }

    func testKnownMarkerStrippedUnknownPreserved() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[BLANK_AUDIO] see [1]"), "see [1]")
    }

    func testArgumentsCarryInitialPromptWithAContextBudgetThatFitsIt() throws {
        let prompt = "Hello, this is a voice note. We use GitHub, VS Code, and the API."
        let transcriber = Transcriber(modelSize: "base.en", language: "en", whisperPrompt: prompt)
        let args = transcriber.arguments(
            modelPath: "/models/ggml-base.en.bin",
            audioURL: URL(fileURLWithPath: "/tmp/input.wav")
        )

        XCTAssertTrue(args.contains("--carry-initial-prompt"))
        // whisper.cpp ignores a prompt when -mc is 0, so the budget must be positive and cover the prompt.
        let budget = try XCTUnwrap(Int(args[try XCTUnwrap(args.firstIndex(of: "-mc")) + 1]))
        XCTAssertTrue(budget >= 32 && budget <= 224)
        XCTAssertEqual(budget, Transcriber.contextBudget(forPrompt: prompt))
    }

    func testPromptIsSkippedForRecordingsLongerThanOneWhisperWindow() {
        let transcriber = Transcriber(modelSize: "base.en", language: "en", whisperPrompt: "Hello, this is a note.")
        let url = URL(fileURLWithPath: "/tmp/input.wav")

        let short = transcriber.arguments(modelPath: "/m.bin", audioURL: url, audioDuration: 20)
        XCTAssertTrue(short.contains("--prompt"))

        let long = transcriber.arguments(modelPath: "/m.bin", audioURL: url, audioDuration: 45)
        XCTAssertFalse(long.contains("--prompt"))
        XCTAssertFalse(long.contains("--carry-initial-prompt"))
        XCTAssertEqual(long[try! XCTUnwrap(long.firstIndex(of: "-mc")) + 1], "0")

        let unreadable = transcriber.arguments(modelPath: "/m.bin", audioURL: url, audioDuration: .infinity)
        XCTAssertFalse(unreadable.contains("--prompt"))
    }

    func testContextBudgetGrowsWithThePromptButStaysWithinWhispersLimit() {
        XCTAssertEqual(Transcriber.contextBudget(forPrompt: "short"), 32)
        XCTAssertTrue(Transcriber.contextBudget(forPrompt: String(repeating: "word ", count: 80)) > 32)
        XCTAssertEqual(Transcriber.contextBudget(forPrompt: String(repeating: "x", count: 5000)), 224)
    }

    func testDefaultPromptHintsPunctuationAndPutsUserTermsFirst() {
        let prompt = Transcriber.defaultPrompt(vocabulary: ["JuiceFly", "KushFly"])
        XCTAssertTrue(prompt.hasPrefix("Hello, this is a voice note."))
        XCTAssertTrue(prompt.contains("We use JuiceFly, KushFly, GitHub, VS Code, Claude Code"))
    }

    func testDefaultPromptStaysSmallEvenWithAHugeVocabulary() {
        let many = (0..<60).map { "Term\($0)" }
        XCTAssertTrue(Transcriber.defaultPrompt(vocabulary: many).count < 250)
    }

    func testPauseMarkerStripped() {
        XCTAssertEqual(Transcriber.stripWhisperMarkers("[ Pause ]"), "")
    }
}
