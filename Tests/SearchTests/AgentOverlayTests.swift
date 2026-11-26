import WebKit
import XCTest
@testable import Search

/// The agent's mark over its page, and the letters tabs wear.
@MainActor
final class AgentOverlayTests: XCTestCase {
    func testABoxFollowsThePagesZoom() {
        XCTAssertEqual(AgentOverlayView.place([10, 20, 100, 30], zoom: 1.5), CGRect(x: 15, y: 30, width: 150, height: 45))
        for bad in [[], [1, 2, 3], [0, 0, 0, 10], [0, 0, 10, -1], [Double.nan, 0, 1, 1], [0, 0, .infinity, 1]] {
            XCTAssertNil(AgentOverlayView.place(bad, zoom: 1), "\(bad)")
        }
    }

    func testItTakesNoClicksAndAddsNothingToThePage() {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let overlay = AgentOverlayView.over(web)
        XCTAssertTrue(AgentOverlayView.over(web) === overlay, "one to a view")
        XCTAssertEqual(overlay.frame, web.bounds)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 50, y: 50)))
        AgentOverlayView.remove(from: web)
        XCTAssertFalse(web.subviews.contains { $0 is AgentOverlayView })
    }

    func testAQuestionsOutlineStaysUntilItIsAnswered() {
        let overlay = AgentOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let box = CGRect(x: 10, y: 10, width: 50, height: 20)
        overlay.show("Waiting for you", at: box, spotlight: true)
        overlay.show("Reading the page", at: nil)
        XCTAssertEqual(overlay.saying, "Waiting for you", "other work doesn't move it")
        XCTAssertEqual(overlay.marked, box)
        overlay.clear()
        XCTAssertEqual(overlay.saying, "")
        XCTAssertFalse(overlay.spotlit)
    }

    func testWhatItSaysQuotesAndCutsThePagesName() {
        XCTAssertEqual(AgentControl.doing("Clicking", ["label": "Filter by date"]), "Clicking “Filter by date”")
        XCTAssertEqual(AgentControl.doing("Clicking", ["label": ""]), "Clicking")
        XCTAssertLessThan(AgentControl.doing("Clicking", ["label": String(repeating: "a", count: 500)]).count, 70)
        XCTAssertFalse(AgentControl.doing("Clicking", ["label": "a\nb\u{0}c"]).contains("\n"))
    }

    func testNumberedAndLocalAddressesWearTheTitlesLetter() {
        XCTAssertEqual(Tab.letter(host: "127.0.0.1", title: "Northwind Journal"), "N")
        XCTAssertEqual(Tab.letter(host: "localhost", title: "· sign in"), "S")
        XCTAssertEqual(Tab.letter(host: "::1", title: "Docs"), "D")
        XCTAssertEqual(Tab.letter(host: "example.com", title: "Zebra"), "E", "a name keeps its own letter")
        XCTAssertEqual(Tab.letter(host: "127.0.0.1", title: "127.0.0.1:8080"), "1", "a title that is the address")
        XCTAssertEqual(Tab.letter(host: "10.0.0.2", title: ""), "1")
        XCTAssertEqual(Tab.letter(host: "", title: "x"), "•")
    }

    func testThePanelKeepsTheTabsATaskLeft() {
        let session = ClaudeSession(world: nil)
        session.seed(question: "q", answer: "a", steps: [])
        let id = Tab().id
        session.left([id])
        session.left([id])
        XCTAssertEqual(session.turns.last?.left, [id])
    }
}
