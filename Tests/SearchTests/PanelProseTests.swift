import XCTest
@testable import Search

/// Claude's answer set as text, with nothing in it to follow or fetch.
@MainActor
final class PanelProseTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    func testBlocks() {
        let text = """
        ## Result

        Two things:
        - one
          - deeper
        1. first

        > said
        > more

        | Name | Price |
        |------|:-----:|
        | Map \\| case | $18 |
        | Short |

        ```swift
        let a = 1
        ```
        ---
        """
        XCTAssertEqual(PanelProse.blocks(text), [
            .heading(2, "Result"), .paragraph("Two things:"), .item("•", 0, "one"), .item("•", 1, "deeper"), .item("1.", 0, "first"),
            .quote("said\nmore"), .table(["Name", "Price"], [["Map | case", "$18"], ["Short", ""]]), .code("swift", "let a = 1"), .rule,
        ])
    }

    func testAFenceStillBeingWrittenIsAllCode() {
        XCTAssertEqual(PanelProse.blocks("```\nhalf <a href=x>"), [.code("", "half <a href=x>")])
    }

    func testWhatLooksNearlyLikeMarkupStaysWords() {
        XCTAssertEqual(PanelProse.blocks("#hashtag\n-5 degrees\n| not a table"), [.paragraph("#hashtag\n-5 degrees\n| not a table")])
    }

    func testNothingInAnAnswerCanBeFollowedOrFetched() {
        let hostile = "[your bank](https://evil.example/login) ![pixel](https://evil.example/p.png) <https://evil.example/a> "
            + "[**bold** link](https://evil.example/b) [file](file:///etc/passwd) [js](javascript:alert(1))"
        let said = PanelProse.inline(hostile)
        for run in said.runs {
            XCTAssertNil(run.link)
            XCTAssertNil(run.imageURL)
        }
        let plain = String(said.characters)
        XCTAssertTrue(plain.contains("your bank (evil.example)"), plain)
        XCTAssertTrue(plain.contains("bold link (evil.example)"), "once for the whole link: \(plain)")
    }

    func testALinkWhoseWordsAreItsSiteIsNotSaidTwice() {
        XCTAssertEqual(String(PanelProse.inline("[example.com](https://example.com/x)").characters), "example.com")
    }

    func testTabsNamed() {
        let text = "See [Tab: Northwind Shop] and [Tab: Docs], then [Tab: Docs] again. [Tab: ] [Tab: unclosed"
        XCTAssertEqual(PanelProse.tabsNamed(in: text), ["Northwind Shop", "Docs"])
        XCTAssertEqual(String(PanelProse.inline("Open [Tab: Docs].").characters), "Open “Docs”.")
    }

    func testPillsAreTheTabsLeftThenThoseNamedAndNeverAPrivateOne() {
        let left = Tab(), named = Tab(), hidden = Tab(shy: true)
        let pills = LeftTabs.pills(ids: [left.id], named: [named.title, "No such tab"], among: [left, named, hidden])
        XCTAssertEqual(pills.first?.id, left.id)
        XCTAssertFalse(pills.contains { $0.id == hidden.id })
    }
}
