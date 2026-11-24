import XCTest
@testable import Search

/// Editing an account must not make its password look newly changed: Health
/// calls a password old by this date.
final class PasswordChangedDateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let longAgo = Date(timeIntervalSince1970: 1_600_000_000)

    private func item(_ password: String, changed: Date?) -> Item {
        Item(host: "example.com", user: "me", password: password, extras: Extras(changed: changed))
    }

    func testNewItemIsChangedNow() {
        XCTAssertEqual(Extras.changedDate(existing: nil, newPassword: "x", now: now), now)
    }

    func testSamePasswordKeepsItsDate() {
        let old = item("same", changed: longAgo)
        XCTAssertEqual(Extras.changedDate(existing: old, newPassword: "same", now: now), longAgo)
    }

    func testSamePasswordWithNoKnownDateStaysUnknown() {
        XCTAssertNil(Extras.changedDate(existing: item("same", changed: nil), newPassword: "same", now: now))
    }

    func testNewPasswordIsChangedNow() {
        XCTAssertEqual(Extras.changedDate(existing: item("old", changed: longAgo), newPassword: "new", now: now), now)
    }
}
