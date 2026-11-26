import XCTest
@testable import Search

/// What the intents do. None of them may send: a run is started by the
/// person's own Send.
@MainActor
final class CairnIntentsTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private func session() -> ClaudeSession {
        ClaudeSession(executable: URL(fileURLWithPath: "/nonexistent/claude"), keep: { _, _ in })
    }

    private func untouched(_ session: ClaudeSession, line: UInt = #line) {
        XCTAssertTrue(session.turns.isEmpty, "nothing was sent", line: line)
        XCTAssertFalse(session.running, line: line)
        XCTAssertNil(session.problem, "nothing was even tried", line: line)
    }

    func testAskingOnlyFillsTheBox() throws {
        let session = session()
        try ShortcutActions.fill("  What is this?\u{1b}\n", in: session)
        XCTAssertEqual(session.draft, "What is this?")
        try ShortcutActions.fill("And this?", in: session)
        XCTAssertEqual(session.draft, "What is this?\nAnd this?", "what you had stays")
        XCTAssertThrowsError(try ShortcutActions.fill(" \n ", in: session))
        XCTAssertEqual(ShortcutActions.words(String(repeating: "a", count: 9000)).count, ShortcutActions.longestAsk)
        untouched(session)
    }

    func testAPlaybookIsCalledAndWaits() throws {
        let session = session()
        try ShortcutActions.prepare(playbook: "/Compare-Tabs", words: "prices", in: session, among: Playbooks.builtIns)
        XCTAssertEqual(session.draft, "/compare-tabs prices")
        XCTAssertThrowsError(try ShortcutActions.prepare(playbook: "nope", words: "", in: session, among: Playbooks.builtIns)) {
            XCTAssertEqual($0 as? ShortcutActions.Refused, .noPlaybook)
        }
        untouched(session)
    }

    func testWhatAShortcutMayCopy() throws {
        let was = Store.settings.object(forKey: VaultedSites.key)
        defer { Store.settings.set(was, forKey: VaultedSites.key) }
        Store.settings.set(["bank.com"], forKey: VaultedSites.key)
        func tab(_ address: String, shy: Bool = false) throws -> Tab {
            let tab = Tab(shy: shy)
            tab.setAddressOptimistically(try XCTUnwrap(URL(string: address)))
            return tab
        }
        XCTAssertNoThrow(try ShortcutActions.mayCopy(try tab("https://example.com/")))
        for (page, why) in [(try tab("https://example.com/", shy: true), ShortcutActions.Refused.privatePage),
                            (try tab("https://login.bank.com/"), .closedSite), (Tab(), .nothing)] {
            XCTAssertThrowsError(try ShortcutActions.mayCopy(page)) { XCTAssertEqual($0 as? ShortcutActions.Refused, why) }
        }
    }

    func testASpaceByName() throws {
        let work = UUID()
        XCTAssertEqual(try ShortcutActions.space(named: " work ", among: [(id: work, name: "Work")]), work)
        XCTAssertThrowsError(try ShortcutActions.space(named: "Home", among: [(id: work, name: "Work")]))
    }
}
