import XCTest
@testable import Search

@MainActor
final class AgentLoopBreakerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    func testTheActionAllowanceIsHard() {
        var breaker = LoopBreaker(limits: LoopLimits(actions: 10, stalled: 5, identical: 3, minutes: 30), at: 0)
        for k in 1...10 { XCTAssertNil(breaker.admit("click", at: Double(k))) }
        let trip = breaker.admit("click", at: 11)
        XCTAssertEqual(trip?.why, .actions)
        XCTAssertEqual(breaker.admit("read", at: 12), trip, "once tripped, always")
    }

    func testTheClockIsHard() {
        var breaker = LoopBreaker(limits: LoopLimits(actions: 100, stalled: 5, identical: 3, minutes: 1), at: 0)
        XCTAssertNil(breaker.admit("click", at: 30))
        XCTAssertEqual(breaker.admit("click", at: 61)?.why, .time)
    }

    func testTheSameActionWithTheSameResultTrips() {
        var other = LoopBreaker(limits: LoopLimits(actions: 100, stalled: 9, identical: 3, minutes: 30), at: 0)
        _ = other.took("click", key: "k", eid: "e", before: "a", after: "b")
        _ = other.took("click", key: "k", eid: "e", before: "a", after: "b")
        let trip = other.took("click", key: "k", eid: "e", before: "a", after: "b")
        XCTAssertEqual(trip?.why, .identical)
        XCTAssertFalse(trip?.trace.isEmpty ?? true)
    }

    func testTheSameControlWithNothingChangingTrips() {
        var breaker = LoopBreaker(limits: LoopLimits(actions: 100, stalled: 3, identical: 9, minutes: 30), at: 0)
        XCTAssertNil(breaker.took("click", key: "1", eid: "e", before: "a", after: "a"))
        XCTAssertNil(breaker.took("click", key: "2", eid: "e", before: "a", after: "a"))
        XCTAssertEqual(breaker.took("click", key: "3", eid: "e", before: "a", after: "a")?.why, .stalled)
    }

    func testReadingTheSamePageOverTrips() {
        var breaker = LoopBreaker(limits: LoopLimits(actions: 100, stalled: 3, identical: 9, minutes: 30), at: 0)
        for _ in 1...3 { XCTAssertNil(breaker.read(fingerprint: "f")) }
        XCTAssertEqual(breaker.read(fingerprint: "f")?.why, .stalled)
        var moving = LoopBreaker(limits: LoopLimits(actions: 100, stalled: 3, identical: 9, minutes: 30), at: 0)
        for k in 1...10 { XCTAssertNil(moving.read(fingerprint: "f\(k)")) }
    }

    func testTheTripSaysLoopSuspectedWithItsTrace() throws {
        var breaker = LoopBreaker(limits: LoopLimits(actions: 1, stalled: 5, identical: 3, minutes: 30), at: 0)
        _ = breaker.admit("click", at: 1)
        let trip = try XCTUnwrap(breaker.admit("click", at: 2))
        let error = try XCTUnwrap(trip.said["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "LOOP_SUSPECTED")
        XCTAssertNotNil(error["trace"])
    }

    func testSettingsOnlyMoveALimitWithinARange() {
        let defaults = UserDefaults(suiteName: "loop-test-\(UUID().uuidString)")!
        XCTAssertEqual(LoopLimits.load(defaults), LoopLimits())
        LoopLimits(actions: 1_000_000, stalled: 0, identical: -3, minutes: 100_000).save(defaults)
        let loaded = LoopLimits.load(defaults)
        XCTAssertEqual([loaded.actions, loaded.stalled, loaded.identical, loaded.minutes], [1000, 2, 2, 240])
    }
}
