import XCTest
@testable import OpenWisprLib

final class BasicTidyTests: XCTestCase {

    func testRepairsMissingPeriodBeforeCapitalizedSegmentStart() {
        XCTAssertEqual(
            BasicTidy.tidy("It's working really great But the only thing I want you to do is test it"),
            "It's working really great. But the only thing I want you to do is test it."
        )
    }

    func testLowercasesCapitalAfterWordThatCannotEndASentence() {
        XCTAssertEqual(
            BasicTidy.tidy("I want you to test all of the different modes and You know like everything"),
            "I want you to test all of the different modes and you know like everything."
        )
    }

    func testDropsDifferentCaseStutter() {
        XCTAssertEqual(
            BasicTidy.tidy("do me a favor and take Take the color from the icon"),
            "Do me a favor and take the color from the icon."
        )
    }

    func testRemovesFillersAndStutteredFunctionWords() {
        XCTAssertEqual(
            BasicTidy.tidy("um so i think we should uh we should go to the the store"),
            "So I think we should go to the store."
        )
        XCTAssertEqual(
            BasicTidy.tidy("Are the are the instructions on how to download it on on github"),
            "Are the instructions on how to download it on github?"
        )
    }

    func testKeepsIntentionalRepeats() {
        XCTAssertEqual(BasicTidy.tidy("that is really really good"), "That is really really good.")
    }

    func testAddsQuestionMarkToQuestions() {
        XCTAssertEqual(BasicTidy.tidy("what time is it"), "What time is it?")
        XCTAssertEqual(BasicTidy.tidy("can you check my email"), "Can you check my email?")
        XCTAssertEqual(BasicTidy.tidy("what I mean is the button is too small"), "What I mean is the button is too small.")
    }

    func testEndsSentencesAfterStockPhrases() {
        XCTAssertEqual(
            BasicTidy.tidy("make it smaller you know what I mean make it very thin"),
            "Make it smaller. Make it very thin."
        )
    }

    func testStripsCommaSetOffFillers() {
        XCTAssertEqual(BasicTidy.stripFillers("it was, you know, fine"), "it was, fine")
        XCTAssertEqual(BasicTidy.stripFillers("so, like, I think it works"), "so, I think it works")
        XCTAssertEqual(BasicTidy.stripFillers("I mean, it works, you know."), "it works.")
        XCTAssertEqual(BasicTidy.stripFillers("I like it, you know?"), "I like it.")
    }

    func testKeepsFillerWordsThatAreRealWords() {
        XCTAssertEqual(BasicTidy.stripFillers("you know that thing I like"), "you know that thing I like")
        XCTAssertEqual(BasicTidy.stripFillers("do you know what I mean?"), "do you know what I mean?")
        XCTAssertEqual(BasicTidy.stripFillers("I like pizza"), "I like pizza")
    }

    func testLeavesFinishedTextAlone() {
        let text = "Go into the app. We just did a bunch of updates. Is it working?"
        XCTAssertEqual(BasicTidy.tidy(text), text)
    }

    func testDoesNotCapitalizeInsideDomainsOrVersions() {
        let text = "Version 3.5 is out, see itch.io for details."
        XCTAssertEqual(BasicTidy.tidy(text), text)
    }

    func testLeavesBracketedMarkersAlone() {
        XCTAssertEqual(BasicTidy.tidy("[ Pause ]"), "[ Pause ]")
    }

    func testEmptyInput() {
        XCTAssertEqual(BasicTidy.tidy("  "), "")
    }
}
