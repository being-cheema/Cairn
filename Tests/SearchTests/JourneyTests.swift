import XCTest
@testable import Search

/// The tabs as trees of what was opened from what.
@MainActor
final class JourneyTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private let ids = (0..<6).map { _ in UUID() }

    func testTreesFollowWhoOpenedWhomThroughClosedTabs() {
        let (a, b, c, d, closed, e) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5])
        // d came from a tab since closed, which came from b.
        let placed = JourneyTree.layout([a, b, c, d, e], parents: [b: a, c: a, d: closed, closed: b])
        XCTAssertEqual(placed.map(\.id), [a, b, d, c, e])
        XCTAssertEqual(placed.map(\.depth), [0, 1, 2, 1, 0])
        XCTAssertEqual(placed.map(\.row), [0, 0, 0, 1, 2])
        XCTAssertEqual(placed.first { $0.id == d }?.parent, b)
        XCTAssertEqual(JourneyTree.branch(b, in: placed), [b, d])
        XCTAssertEqual(JourneyTree.branch(a, in: placed), [a, b, d, c])
    }

    func testALoopStillDrawsEveryTabOnce() {
        let (a, b, c) = (ids[0], ids[1], ids[2])
        let placed = JourneyTree.layout([a, b, c], parents: [a: b, b: a, c: c])
        XCTAssertEqual(Set(placed.map(\.id)), [a, b, c])
        XCTAssertEqual(placed.count, 3)
        XCTAssertTrue(JourneyTree.layout([], parents: [:]).isEmpty)
    }

    func testDeadEndsAreOnlyUnkeptEndsOfABranch() {
        let (a, b, c, d, e) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        // a -> b -> c; a -> d; e alone.
        let placed = JourneyTree.layout([a, b, c, d, e], parents: [b: a, c: b, d: a])
        XCTAssertEqual(JourneyTree.deadEnds(placed, current: nil) { _ in true }, [c, d], "never a tree's first tab, or one with children")
        XCTAssertEqual(JourneyTree.deadEnds(placed, current: d) { _ in true }, [c], "never the one on screen")
        XCTAssertEqual(JourneyTree.deadEnds(placed, current: nil) { $0 != c }, [d], "never one something keeps open")
    }

    func testPrivateTabsAreNotRemembered() {
        let log = JourneyLog()
        let plain = Tab(), other = Tab(), secret = Tab(shy: true)
        log.opened(secret, from: plain)
        log.opened(other, from: secret)
        XCTAssertTrue(log.parents.isEmpty)
        log.opened(other, from: plain)
        XCTAssertEqual(log.parents, [other.id: plain.id])
        XCTAssertNil(other.opener, "what lets a page close its tab is left alone")
        let swapped = UUID()
        log.replaced(plain.id, with: swapped)
        XCTAssertEqual(log.parents[other.id], swapped)
    }

    func testTheShortcutIsItsOwn() {
        let key = Command.named("view.journey")?.defaultKey
        XCTAssertEqual(key, KeyCombo("g", option: true))
        XCTAssertEqual(Command.all.filter { $0.defaultKey == key }.count, 1)
    }
}
