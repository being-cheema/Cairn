import XCTest
@testable import Search

/// A result as a card: plain words, within limits, its sources the browser's.
@MainActor
final class ArtifactTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    // Not made with the test case: XCTest makes them all before any setUp.
    private lazy var tab = Tab().id
    private func source(_ handle: String) -> Artifact.Source? {
        handle == "p1" ? Artifact.Source(tab: tab, site: "a.example", address: "https://a.example/x") : nil
    }

    private func parsed(_ request: [String: Any]) -> Result<Artifact, Artifact.Problem> { Artifact.parse(request, source: source) }

    func testATable() throws {
        let made = try parsed(["kind": "table", "title": "Gear", "columns": ["Name", "Price"],
                               "rows": [[["text": "Map", "source_page": "p1"], ["text": "$18", "source_page": "p9"]], ["Compass"], "junk"]]).get()
        XCTAssertEqual(made.rows.count, 2)
        XCTAssertEqual(made.rows[0][0].source?.site, "a.example")
        XCTAssertNil(made.rows[0][1].source, "a handle that isn't the task's names nothing")
        XCTAssertEqual(made.rows[1].map(\.text), ["Compass", ""])
    }

    func testWhatIsRefused() {
        XCTAssertEqual(parsed(["kind": "chart", "title": "x"]), .failure(.kind))
        XCTAssertEqual(parsed(["kind": "table", "title": " "]), .failure(.title))
        XCTAssertEqual(parsed(["kind": "table", "title": "x"]), .failure(.columns))
        XCTAssertEqual(parsed(["kind": "brief", "title": "x", "sections": []]), .failure(.empty))
    }

    func testEverythingHasALimit() throws {
        let made = try parsed(["kind": "table", "title": String(repeating: "t", count: 900),
                               "columns": Array(repeating: "c", count: 40),
                               "rows": Array(repeating: [String(repeating: "x\n", count: 4000)], count: 500)]).get()
        XCTAssertLessThanOrEqual(made.title.count, 201)
        XCTAssertEqual(made.columns.count, Artifact.mostColumns)
        XCTAssertEqual(made.rows.count, Artifact.mostRows)
        XCTAssertLessThanOrEqual(made.rows[0][0].text.count, 501)
        XCTAssertFalse(made.rows[0][0].text.contains("\n"))
    }

    func testMarkdownKeepsAPagesWordsInTheirCell() throws {
        let made = try parsed(["kind": "table", "title": "A [x](https://evil.example)", "columns": ["n"],
                               "rows": [[["text": "a | b <img> [c](d)", "source_page": "p1"]]]]).get()
        let text = made.markdown
        XCTAssertTrue(text.contains(#"a \| b \<img\> \[c\](d) (https://a.example/x)"#), text)
        XCTAssertTrue(text.hasPrefix(#"## A \[x\](`https://evil.example`)"#), text)
    }

    func testAChecklist() throws {
        let made = try parsed(["kind": "checklist", "title": "Pack", "sections": [["heading": "Map", "body": "paper"], ["heading": "Water"]]]).get()
        XCTAssertEqual(made.markdown, "## Pack\n\n- [ ] Map: paper\n- [ ] Water\n")
    }

    func testAPanelTurnHoldsOnlySoMany() throws {
        let session = ClaudeSession(world: nil)
        let made = try parsed(["kind": "brief", "title": "t", "sections": [["heading": "h"]]]).get()
        XCTAssertFalse(session.add(made), "no turn to show it in")
        session.seed(question: "q", answer: "", steps: [])
        for _ in 0..<6 { XCTAssertTrue(session.add(made)) }
        XCTAssertFalse(session.add(made))
    }
}
