import XCTest
@testable import Search

/// Triage Tabs and a space's page size.
@MainActor
final class TabTriageTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func item(_ address: String, _ vector: [Double]? = nil) throws -> Triage.Item {
        Triage.Item(id: UUID(), title: address, url: try XCTUnwrap(URL(string: address)), vector: vector)
    }

    func testTabsGroupBySiteThenByMeaning() throws {
        let items = try [item("https://birds.test/owl", [1, 0]), item("https://news.example/a", [0, 1]),
                         item("https://wildlife.invalid/hawk", [0.9, 0.1]), item("https://www.news.example/b", [1, 0])]
        let clusters = Triage.clusters(items)
        XCTAssertEqual(clusters.map { $0.items.map(\.id) },
                       [[items[0].id, items[2].id], [items[1].id, items[3].id]], "a site's tabs stay together, whatever their words")
        XCTAssertEqual(clusters[1].name, "news.example")
        XCTAssertEqual(Triage.clusters(items.map { var each = $0; each.vector = nil; return each }).count, 3)
    }

    func testOnlyTheSameAddressIsADuplicate() throws {
        let items = try [item("https://a.test/mail#inbox"), item("https://a.test/mail#sent"),
                         item("https://a.test/mail#inbox"), item("https://a.test/mail")]
        XCTAssertEqual(Triage.duplicates(items).map { $0.map(\.id) }, [[items[0].id, items[2].id]])
    }

    func testPrivateAgentAndPinnedTabsAreLeftOutAndNothingIsSent() throws {
        let browser = Browser()
        let url = try XCTUnwrap(URL(string: "about:blank"))
        let agents = browser.benchOpen(url, agent: true, store: .nonPersistent())
        XCTAssertFalse(browser.triageTabs.contains { $0.id == agents.id })
        XCTAssertEqual(browser.triageAskClaude([agents.id]), 0)
        XCTAssertTrue(browser.claude.mentions.isEmpty)
        XCTAssertEqual(browser.claude.draft, Triage.synthesis)
        XCTAssertTrue(browser.claude.turns.isEmpty)
        XCTAssertFalse(browser.claude.running)
    }

    func testTheShortcutIsNobodyElses() throws {
        let key = try XCTUnwrap(Command.named("tabs.triage")?.defaultKey)
        XCTAssertEqual(key.display, "⇧⌘K")
        XCTAssertEqual(Command.all.filter { $0.defaultKey == key }.map(\.id), ["tabs.triage"])
        XCTAssertFalse(KeyCombo.isReserved(key))
    }

    func testASpacesPageSizeIsKeptAndAnOldListHasNone() throws {
        var space = Space.first()
        XCTAssertNil(space.pageSize)
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Personal","colour":0}"#
        XCTAssertNil(try JSONDecoder().decode(Space.self, from: Data(old.utf8)).pageSize)
        space.pageSize = PageSize.phone.rawValue
        let again = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(space))
        XCTAssertEqual(again.pageSize.flatMap(PageSize.init)?.size, CGSize(width: 393, height: 852))
    }
}
