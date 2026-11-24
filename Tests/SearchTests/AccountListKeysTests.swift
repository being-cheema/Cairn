import AppKit
import XCTest
@testable import Search

/// The accounts under a sign-in box from the keyboard: ↓ and ↑ light a row,
/// Return takes it as a click would. Until a row is lit, Return and ↑ stay the
/// page's.
@MainActor
final class AccountListKeysTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private var suite = ""
    private var store: UserDefaults!

    override func setUp() {
        _ = NSApplication.shared
        suite = "bld-account-keys-store-\(getpid())"
        store = UserDefaults(suiteName: suite)
    }

    override func tearDown() { store.removePersistentDomain(forName: suite) }

    private func browser() -> Browser {
        let browser = Browser(record: WindowRecord())
        return browser
    }

    private func list(on tab: UUID) -> Browser.Suggesting {
        var list = Browser.Suggesting(
            tab: tab, spot: CGRect(x: 40, y: 120, width: 280, height: 30),
            logins: [Kept(host: "mail.example.com", user: "ann"), Kept(host: "example.com", user: "bob")],
            host: "mail.example.com", clear: false)
        list.shown = Date().addingTimeInterval(-1)
        return list
    }

    func testTheRowsInTheOrderTheyAreDrawn() {
        let list = list(on: UUID())
        XCTAssertEqual(list.choices, [
            .login(Kept(host: "mail.example.com", user: "ann")),
            .login(Kept(host: "example.com", user: "bob")),
        ])
        XCTAssertEqual(list.othersFrom, 1, "the rest of the site's under a line")
    }

    func testArrowsMoveTheLight() {
        let browser = browser()
        defer { browser.closeAll() }
        let tab = UUID()
        browser.activeID = tab
        browser.testSuggest(list(on: tab))
        XCTAssertFalse(browser.moveChoice(by: -1), "↑ with nothing lit is the page's")
        XCTAssertFalse(browser.takeLitChoice(), "Return with nothing lit is the page's")
        XCTAssertTrue(browser.moveChoice(by: 1))
        XCTAssertEqual(browser.suggesting?.lit, 0)
        XCTAssertTrue(browser.moveChoice(by: 1))
        XCTAssertTrue(browser.moveChoice(by: 1))
        XCTAssertEqual(browser.suggesting?.lit, 1, "↓ on the last stays there")
        XCTAssertTrue(browser.moveChoice(by: -1))
        XCTAssertEqual(browser.suggesting?.lit, 0)
        XCTAssertTrue(browser.moveChoice(by: -1), "↑ from the first is the list's: back to the box")
        XCTAssertNil(browser.suggesting?.lit)
    }

    func testOnlyTheTabInFront() {
        let browser = browser()
        defer { browser.closeAll() }
        browser.activeID = UUID()
        browser.testSuggest(list(on: UUID()))
        XCTAssertFalse(browser.moveChoice(by: 1))
        XCTAssertNil(browser.suggesting?.lit)
    }

    func testReturnTakesTheRowLit() async throws {
        let browser = browser()
        defer { browser.closeAll() }
        let tab = UUID()
        browser.activeID = tab
        var up = list(on: tab)
        // Just up: a click would be refused, a row come to with the arrows isn't.
        up.shown = Date()
        browser.testSuggest(up)
        _ = browser.moveChoice(by: 1)
        XCTAssertEqual(browser.suggesting?.choices[browser.suggesting?.lit ?? 0], .login(Kept(host: "mail.example.com", user: "ann")))
        XCTAssertTrue(browser.takeLitChoice())
        // No real tab behind the list in a test: a pick finds none and fills nothing.
    }

}
