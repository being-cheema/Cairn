import XCTest
import WebKit
@testable import Search

/// An agent's task space: tabs in a cookie store of their own, that leave
/// nothing of the page behind when they close, and none of yours in them.
@MainActor
final class TaskSpaceTests: XCTestCase {
    func testATaskTabUsesTheStoreItIsGiven() {
        let browser = Browser(record: WindowRecord())
        let space = WKWebsiteDataStore.nonPersistent()
        let tab = browser.benchOpen(URL(string: "about:blank")!, agent: true, store: space)
        XCTAssertTrue(tab.store === space)
        XCTAssertFalse(tab.store.isPersistent)
        XCTAssertFalse(tab.store === Spaces.store(for: Spaces.current), "never the person's own cookies")
        XCTAssertTrue(tab.agent)
    }

    func testWithoutAStoreATabIsAsItWas() {
        let browser = Browser(record: WindowRecord())
        let tab = browser.benchOpen(URL(string: "about:blank")!, agent: true)
        XCTAssertTrue(tab.store.isPersistent)
    }

    func testTwoTasksDoNotShareACookieStore() {
        let browser = Browser(record: WindowRecord())
        let a = browser.benchOpen(URL(string: "about:blank")!, agent: true, store: .nonPersistent())
        let b = browser.benchOpen(URL(string: "about:blank")!, agent: true, store: .nonPersistent())
        XCTAssertFalse(a.store === b.store)
    }

    func testAClosedTaskTabCannotBeReopenedInYourCookies() {
        let browser = Browser(record: WindowRecord())
        let before = browser.recentlyClosed.count
        let tab = browser.benchOpen(URL(string: "https://example.invalid/")!, agent: true, store: .nonPersistent())
        browser.close(tab)
        XCTAssertEqual(browser.recentlyClosed.count, before)
    }
}
