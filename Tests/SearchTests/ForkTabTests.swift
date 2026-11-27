import XCTest
@testable import Search

@MainActor
final class ForkTabTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func make() -> Browser {
        let browser = Browser()
        Browsers.register(browser)
        return browser
    }

    func testAForkIsAnotherTabInTheSameStore() throws {
        let browser = make()
        defer { browser.window = nil; browser.closeAll(); Browsers.discard(browser) }
        let source = browser.open(try XCTUnwrap(URL(string: "https://example.com/a")), foreground: true)
        let before = browser.tabs.count
        let fork = try XCTUnwrap(browser.forkTab())
        XCTAssertEqual(browser.tabs.count, before + 1)
        XCTAssertNotEqual(fork.id, source.id)
        XCTAssertTrue(fork.store === source.store)
        XCTAssertFalse(fork.shy)
        XCTAssertEqual(fork.address, source.address)
        XCTAssertEqual(browser.activeID, fork.id)
    }

    func testAPrivateTabForksPrivateAndNeverIntoYourStore() throws {
        let browser = make()
        defer { browser.window = nil; browser.closeAll(); Browsers.discard(browser) }
        let source = browser.benchOpen(try XCTUnwrap(URL(string: "https://example.com/p")), shy: true)
        source.agent = false
        XCTAssertTrue(source.bench)
        // A bench tab is not forked at all; a private tab of yours is.
        let shy = browser.open(try XCTUnwrap(URL(string: "https://example.com/q")), foreground: true, from: source)
        XCTAssertTrue(shy.shy)
        let fork = try XCTUnwrap(browser.forkTab())
        XCTAssertTrue(fork.shy)
        XCTAssertTrue(fork.store === shy.store)
        XCTAssertFalse(fork.store === Spaces.store(for: browser.spaceID))
    }

    func testAnAgentsTabIsNeverForked() throws {
        let browser = make()
        defer { browser.window = nil; browser.closeAll(); Browsers.discard(browser) }
        let tab = browser.benchOpen(try XCTUnwrap(URL(string: "https://example.com/t")), agent: true, store: .nonPersistent())
        browser.activeID = tab.id
        let before = browser.tabs.count
        XCTAssertNil(browser.forkTab())
        XCTAssertEqual(browser.tabs.count, before)
        XCTAssertFalse(ForkTab.allows(tab))
    }

    func testTheShortcutIsFreeAndNamed() {
        let forks = Command.all.filter { $0.id == "tabs.fork" }
        XCTAssertEqual(forks.count, 1)
        let combo = forks.first?.defaultKey
        XCTAssertNotNil(combo)
        XCTAssertEqual(Command.all.filter { $0.defaultKey == combo }.count, 1, "no other command has it")
    }
}
