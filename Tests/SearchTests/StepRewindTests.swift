import XCTest
@testable import Search

@MainActor
final class StepRewindTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testTheLogKeepsTheLatestFewAndPopsNewestFirst() {
        var log = StepLog()
        let tab = UUID()
        for i in 0..<15 { log.keep(StepCheckpoint(tab: tab, state: i, what: "step \(i)")) }
        XCTAssertEqual(log.items.count, StepLog.most)
        XCTAssertEqual(log.pop()?.what, "step 14")
        XCTAssertEqual(log.last?.what, "step 13")
        log.clear()
        XCTAssertNil(log.last)
    }

    func testAnUnbuiltTabTakesTheStateBackAndRewindIsOnlyYourClick() throws {
        let browser = Browser()
        Browsers.register(browser)
        defer { Browsers.discard(browser) }
        let tab = Tab(space: browser.spaceID)
        tab.restore(url: try XCTUnwrap(URL(string: "https://example.com/")), title: "")
        tab.rewind(to: "state-a" as NSString)
        XCTAssertEqual(tab.keepsake as? NSString, "state-a")
        // Not running, nothing kept: nothing to rewind; and no click, no rewind.
        let claude = browser.claude
        XCTAssertFalse(claude.canRewind)
        XCTAssertFalse(claude.rewind(event: nil))
    }

    func testTheWarningSaysPageOnly() {
        XCTAssertTrue(ClaudeSession.rewindWarning.contains("page only"))
        XCTAssertTrue(ClaudeSession.rewindWarning.contains("unsend"))
    }
}
