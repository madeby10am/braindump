import XCTest
@testable import OpenWisprLib

final class VocabularyTests: XCTestCase {

    func testFixesCasingOfDeveloperTerms() {
        XCTAssertEqual(
            Vocabulary.apply("push it to github and check the api and the json in php"),
            "push it to GitHub and check the API and the JSON in PHP"
        )
    }

    func testFixesSplitAndMisheardSpellings() {
        XCTAssertEqual(Vocabulary.apply("open it in vs code"), "open it in VS Code")
        XCTAssertEqual(Vocabulary.apply("the quad code session"), "the Claude Code session")
        XCTAssertEqual(Vocabulary.apply("a word press plugin on git hub"), "a WordPress plugin on GitHub")
        XCTAssertEqual(Vocabulary.apply("the a p i returns j son"), "the API returns JSON")
    }

    func testFixesWhatWhisperActuallyHears() {
        XCTAssertEqual(
            Vocabulary.apply("I opened versus code and checked the appie response then pushed it to jit hub"),
            "I opened VS Code and checked the API response then pushed it to GitHub"
        )
    }

    func testAppliesCustomTerms() {
        XCTAssertEqual(
            Vocabulary.apply("juicefly and braindump", custom: ["JuiceFly", "BrainDump"]),
            "JuiceFly and BrainDump"
        )
    }

    func testLeavesDomainsAndPathsAlone() {
        let text = "see github.com/api and api-key and docs@api.dev"
        XCTAssertEqual(Vocabulary.apply(text), text)
    }

    func testHintPutsCustomTermsFirstWithoutDuplicates() {
        let hint = Vocabulary.hint(custom: ["JuiceFly", "github"])
        XCTAssertEqual(Array(hint.prefix(2)), ["JuiceFly", "github"])
        XCTAssertEqual(hint.filter { $0.lowercased() == "github" }.count, 1)
    }
}
