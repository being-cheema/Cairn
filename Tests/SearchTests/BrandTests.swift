import XCTest
@testable import Search

/// What a fork that nobody has configured does: nothing. The updater must
/// not schedule or send anything without a feed of the builder's own, and
/// nothing may be accepted as a release without the builder's team.
final class BrandTests: XCTestCase {
    @MainActor func testNoFeedMeansNoUpdater() {
        // A test run has no Info.plist of the builder's, so none is set.
        XCTAssertNil(Brand.feedURL)
        XCTAssertNil(Updater.feed)
        XCTAssertFalse(Updater.configured)
    }

    @MainActor func testACheckWithoutAFeedAsksNobody() {
        let updater = Updater.shared
        var answered = false
        var found: Updater.Release?
        updater.check { answered = true; found = $0 }
        // Answered at once with nothing found, and never marked as checking:
        // a request in flight would have set it.
        XCTAssertTrue(answered)
        XCTAssertNil(found)
        XCTAssertFalse(updater.checking)
        XCTAssertNil(updater.lastChecked)
    }

    @MainActor func testStartingTheUpdaterWithoutAFeedSchedulesNothing() {
        let updater = Updater.shared
        var said: [String] = []
        updater.checkIfDue { said.append($0) }
        XCTAssertFalse(updater.checking)
        XCTAssertTrue(said.isEmpty)
        XCTAssertFalse(updater.hasTimer, "no hourly timer without a feed")
    }

    func testNoTeamMeansNoRequirementToMeet() {
        XCTAssertNil(Brand.teamID)
        XCTAssertNil(Updater.developerID(team: Updater.team, identifier: Brand.engineIdentifier))
    }

    func testIdentifiersAreOneBundleIdsChildren() {
        XCTAssertEqual(Brand.engineIdentifier, Brand.bundleID + ".ai-engine")
        XCTAssertEqual(Brand.feedIdentifier, Brand.bundleID + ".appcast")
        XCTAssertEqual(Brand.service("proxy"), Brand.bundleID + ".proxy")
    }
}
