import XCTest
@testable import Search

@MainActor
final class SelectionAskTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testTheMessageKeepsToTheAttachedWordsAndNeverCarriesThePage() {
        let said = SelectionAsk.message("what does this mean?")
        XCTAssertTrue(said.contains("what does this mean?"))
        XCTAssertTrue(said.contains("Answer only from that text"))
        XCTAssertTrue(SelectionAsk.message("  ").contains("Explain this."))
    }

    func testTheExcerptIsOneShortLine() {
        XCTAssertEqual(SelectionAsk.excerpt("a\n\n b   c"), "a b c")
        XCTAssertLessThanOrEqual(SelectionAsk.excerpt(String(repeating: "word ", count: 100)).count, 141)
    }

    func testTheKeyIsFreeAndItOnlyOpensACard() {
        let found = Command.all.filter { $0.id == "edit.askSelection" }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(Command.all.filter { $0.defaultKey == found.first?.defaultKey }.count, 1)
    }

    func testAPrivateTabIsNeverAsked() throws {
        let browser = Browser()
        Browsers.register(browser)
        defer { Browsers.discard(browser) }
        let shy = browser.benchOpen(try XCTUnwrap(URL(string: "https://example.com/")), shy: true)
        browser.activeID = shy.id
        XCTAssertFalse(Mentions.mayName(shy))
        browser.askAboutSelection()
        XCTAssertTrue(browser.claude.turns.isEmpty)
        XCTAssertTrue(browser.claude.draft.isEmpty)
    }
}
