import XCTest
@testable import Search

/// The iPhone beta's quieter places (IPhoneAsk.swift): when they offer it,
/// that one "Not now" or one address from anywhere ends it, and that each
/// place's press says where it was made. No window, no network.
@MainActor
final class IPhoneAskTests: XCTestCase {
    private var store: UserDefaults!
    private let suite = "io.github.being-cheema.cairn.iphoneask-tests-\(getpid())"

    override func setUp() {
        super.setUp()
        store = UserDefaults(suiteName: suite)
        store.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testStaysOffWhateverHappens() {
        XCTAssertFalse(IPhoneAsk.on)
        XCTAssertFalse(IPhoneAsk.open(store))
        IPhoneAsk.dismiss(store)
        XCTAssertFalse(IPhoneAsk.open(store))
        XCTAssertFalse(IPhoneAsk.onNewTab(store))
    }

    func testNoAnswerBringsItBack() {
        OptIn.remember(.news(iPhoneBeta: false), in: store)
        XCTAssertFalse(IPhoneAsk.open(store), "the Mac news list alone: still off")
        store.removePersistentDomain(forName: suite)
        OptIn.remember(.iPhoneBeta, in: store)
        XCTAssertFalse(IPhoneAsk.open(store), "asked for the beta from any place")
    }

    func testNewTabNeverOffersItAtAnyTime() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertFalse(IPhoneAsk.onNewTab(store, now: start))
        XCTAssertFalse(IPhoneAsk.onNewTab(store, now: start.addingTimeInterval(2.9 * 86_400)))
        XCTAssertFalse(IPhoneAsk.onNewTab(store, now: start.addingTimeInterval(3.1 * 86_400)))
    }

    func testEachPlaceTagsItsSource() throws {
        let base = URL(string: "https://searchbrowser.app/api/")!
        let expected: [IPhoneAsk.Spot: String] = [.about: "app-about", .help: "app-help", .newTab: "app-newtab"]
        for spot in IPhoneAsk.Spot.allCases {
            let request = OptIn.request(email: "a@example.com", list: .iPhoneBeta, source: spot.source, base: base)
            XCTAssertEqual(request.url?.absoluteString, "https://searchbrowser.app/api/ios-beta")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["email", "source"])
            XCTAssertEqual(body["source"] as? String, expected[spot])
        }
    }
}
