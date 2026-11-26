import XCTest
@testable import Search

/// What an agent's tab may load, and what is held on its way out.
@MainActor
final class NavigationPolicyTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private func url(_ text: String) -> URL { URL(string: text) ?? URL(fileURLWithPath: "/bad") }

    func testWhereOpenAndGoMayPoint() {
        XCTAssertEqual(try? NavigationPolicyEngine.destination("example.com", allowed: []).get().absoluteString, "https://example.com")
        XCTAssertEqual(NavigationPolicyEngine.destination("file:///etc/passwd", allowed: []), .failure(.notWeb))
        XCTAssertEqual(NavigationPolicyEngine.destination("http://192.168.1.1/", allowed: []), .failure(.privateAddress))
        XCTAssertNotNil(try? NavigationPolicyEngine.destination("http://127.0.0.1:1/", allowed: ["127.0.0.1"]).get())
    }

    func testWhatNeverLoads() {
        XCTAssertTrue(NavigationPolicyEngine.neverLoads(url("https://a.com"), download: true))
        XCTAssertTrue(NavigationPolicyEngine.neverLoads(url("file:///tmp/x"), download: false))
        XCTAssertFalse(NavigationPolicyEngine.neverLoads(nil, download: false), "nothing to fetch")
        XCTAssertFalse(NavigationPolicyEngine.neverLoads(url("https://a.com"), download: false))
    }

    func testScreening() {
        XCTAssertEqual(NavigationPolicyEngine.screen(url("about:blank"), allowed: []), .notWeb)
        XCTAssertEqual(NavigationPolicyEngine.screen(url("http://localhost/"), allowed: []), .privateAddress)
        XCTAssertEqual(NavigationPolicyEngine.screen(url("https://example.com/"), allowed: []), .lookUp("example.com"))
        XCTAssertEqual(NavigationPolicyEngine.screen(url("http://127.0.0.1/"), allowed: ["127.0.0.1"]), .clear)
    }

    private func send(_ method: String, from: Bool = true, to: Bool = true, now: TimeInterval = 100, grant: TimeInterval = 0) -> NavigationPolicyEngine.Send {
        NavigationPolicyEngine.send(method: method, to: url("https://example.com/x"), fromMainFrame: from, toMainFrame: to,
                                    now: now, grantedUntil: grant)
    }

    func testAFormOnItsWayOut() {
        XCTAssertEqual(send("GET"), .go)
        guard case .ask(let hold) = send("POST") else { return XCTFail("a POST is asked about") }
        XCTAssertEqual(hold.reason, .submit)
        XCTAssertEqual(send("POST", grant: 105), .covered, "your Approve just covered it")
        XCTAssertNotEqual(send("POST", grant: 99), .covered, "an old Approve covers nothing")
        XCTAssertEqual(send("POST", from: false, to: false), .go, "a frame's own post")
        XCTAssertNotEqual(send("POST", from: false, to: true), .go, "a frame taking over the tab")
        XCTAssertNotEqual(send("POST", from: true, to: false), .go, "the page posting into a frame")
    }
}
