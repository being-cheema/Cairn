import XCTest
@testable import Search

/// The words of an action's receipt, its failure codes and its repeats.
@MainActor
final class AgentActionReceiptTests: XCTestCase {
    private func state(hash: String = "a", url: String = "https://a.example/", nodes: [String: String] = [:], text: Int = 100,
                       sample: String = "", captcha: Bool = false, password: Bool = false, requests: Int = 0) -> PageState {
        var s = PageState()
        s.hash = hash; s.url = url; s.nodes = nodes; s.textLength = text; s.sample = sample
        s.captcha = captcha; s.password = password; s.requestTotal = requests
        return s
    }

    func testEveryCodeHasAHintAndTheGuessesSayTheyAre() {
        for code in ActionFailure.allCases {
            XCTAssertFalse(code.hint.isEmpty)
            XCTAssertEqual(code.said["code"] as? String, code.rawValue)
            XCTAssertEqual(code.said["heuristic"] != nil, code.heuristic, code.rawValue)
        }
        for code in [ActionFailure.authWall, .captcha, .paywall, .rateLimit] { XCTAssertTrue(code.heuristic) }
        XCTAssertFalse(ActionFailure.occluded.heuristic)
        XCTAssertTrue(ActionFailure.captcha.hint.contains("Don't try to pass it"))
    }

    func testTheOldCodesGetTheirNewNames() {
        XCTAssertEqual(ActionFailure.from(refusal: "obscured"), .occluded)
        XCTAssertEqual(ActionFailure.from(refusal: "detached"), .detached)
        XCTAssertEqual(ActionFailure.from(refusal: "disabled"), .disabled)
        XCTAssertNil(ActionFailure.from(refusal: "bad_text"))
    }

    func testARefusalCarriesItsTaxonomyAndAHint() throws {
        let said = AgentRefusal(code: "obscured", message: "Covered by div").said["error"] as? [String: Any]
        XCTAssertEqual(said?["failure"] as? String, "OCCLUDED")
        XCTAssertEqual(said?["code"] as? String, "obscured", "the code an agent already branches on stays")
        XCTAssertTrue((said?["hint"] as? String ?? "").contains("covers"))
        XCTAssertNil((AgentRefusal(code: "bad_text", message: "x").said["error"] as? [String: Any])?["failure"])
    }

    func testWallsAreOnlyBlamedWhenTheyAreNew() {
        let plain = state(sample: "welcome")
        XCTAssertEqual(ActionFailure.wall(before: plain, after: state(sample: "please verify you are human", captcha: true)), .captcha)
        XCTAssertEqual(ActionFailure.wall(before: plain, after: state(sample: "error 429 too many requests")), .rateLimit)
        XCTAssertEqual(ActionFailure.wall(before: plain, after: state(sample: "subscribe to continue reading")), .paywall)
        XCTAssertEqual(ActionFailure.wall(before: plain, after: state(url: "https://a.example/login", sample: "sign in", password: true)), .authWall)
        XCTAssertNil(ActionFailure.wall(before: state(sample: "subscribe to continue reading"), after: state(sample: "subscribe to continue reading")))
        XCTAssertNil(ActionFailure.wall(before: plain, after: plain))
    }

    func testTheDeltaIsCountsAndNeverThePagesWords() {
        let before = state(nodes: ["a": "1", "b": "2"], text: 100)
        let after = state(hash: "b", url: "https://a.example/next", nodes: ["a": "1", "b": "9", "c": "3"], text: 140)
        let delta = PageDelta(from: before, to: after)
        XCTAssertEqual([delta.added, delta.removed, delta.changed], [1, 0, 1])
        XCTAssertTrue(delta.summary.hasPrefix("The address changed"))
        XCTAssertTrue(delta.summary.contains("40 characters longer"))
        XCTAssertEqual(PageDelta(from: before, to: before).summary, "Nothing the browser could see changed")
    }

    func testTheReceiptHasWhatWasPromisedAndLabelsWhatItCantSee() throws {
        var after = state(hash: "b", url: "https://a.example/next", requests: 2)
        after.requests = [.init(via: "fetch", origin: "https://api.a.example", status: nil), .init(via: "xmlhttprequest", origin: "https://t.example", status: 200)]
        after.focus = .init(eid: "12345678", role: "textbox", name: "Email")
        let made = ActionReceipt.make(id: "act-1", action: "click", origin: "a.example", before: state(), after: after, dedupe: "k",
                                      url: { $0 }, label: { $0 })
        for key in ["action_id", "eid", "before_hash", "after_hash", "delta_summary", "side_effects", "dedupe_key"] { XCTAssertNotNil(made[key], key) }
        let effects = try XCTUnwrap(made["side_effects"] as? [String: Any])
        for key in ["network", "navigations", "storage_writes", "focus_changes"] { XCTAssertNotNil(effects[key], key) }
        let network = try XCTUnwrap(effects["network"] as? [String: Any])
        XCTAssertEqual((network["requests"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue((network["best_effort"] as? String ?? "").contains("not a complete record"))
        XCTAssertEqual((effects["navigations"] as? [Any])?.count, 1)
        XCTAssertEqual((effects["focus_changes"] as? [Any])?.count, 1)
    }

    func testTheDedupeKeyIsStableAndTellsThingsApart() {
        let a = Dedupe.key(origin: "a.example", action: "click", eid: "12345678", values: "")
        XCTAssertEqual(a.count, 16)
        XCTAssertEqual(a, Dedupe.key(origin: "a.example", action: "click", eid: "12345678", values: ""))
        XCTAssertNotEqual(a, Dedupe.key(origin: "a.example", action: "click", eid: "12345679", values: ""))
        XCTAssertNotEqual(a, Dedupe.key(origin: "b.example", action: "click", eid: "12345678", values: ""))
        XCTAssertNotEqual(Dedupe.values([("1", "x")]), Dedupe.values([("1", "y")]))
        XCTAssertEqual(Dedupe.values([("2", "y"), ("1", "x")]), Dedupe.values([("1", "x"), ("2", "y")]))
    }

    func testOnlyARepeatOnAPageLeftAsItWasIsHeld() {
        var ledger = DedupeLedger()
        ledger.record("k", before: "p1", after: "p2", at: 0)
        XCTAssertTrue(ledger.isRepeat("k", pageNow: "p2", at: 10), "the same thing on the page it left")
        XCTAssertFalse(ledger.isRepeat("k", pageNow: "p3", at: 10), "the page has moved on: next page, say")
        XCTAssertFalse(ledger.isRepeat("k", pageNow: "p2", at: 500), "long ago")
        XCTAssertFalse(ledger.isRepeat("other", pageNow: "p2", at: 10))
        ledger.record("quiet", before: "p1", after: "p1", at: 0)
        XCTAssertFalse(ledger.isRepeat("quiet", pageNow: "p1", at: 1), "it did nothing: trying again is not a second one")
    }

    func testWhatIsGuardedAgainstRepeating() {
        XCTAssertTrue(Dedupe.guards(action: "click", role: "button"))
        XCTAssertFalse(Dedupe.guards(action: "click", role: "link"))
        XCTAssertFalse(Dedupe.guards(action: "type", role: "textbox"))
        XCTAssertTrue(Dedupe.guards(action: "type", role: "textbox", submit: true))
        XCTAssertTrue(Dedupe.guards(action: "press", role: "", key: "Enter"))
        XCTAssertFalse(Dedupe.guards(action: "press", role: "", key: "Tab"))
    }
}

@MainActor
final class TrailStepTests: XCTestCase {
    func testAStepIsMadeFromAReceiptAndSaysWhatItDid() throws {
        let receipt: [String: Any] = ["action_id": "act-3", "action": "click", "eid": "12345678", "delta_summary": "2 controls appeared",
            "side_effects": ["network": ["requests": [["via": "fetch"]]], "navigations": [["from": "a", "to": "b"]],
                             "storage_writes": ["changed": 1]] as [String: Any]]
        let step = try XCTUnwrap(TrailStep(receipt: receipt, failure: nil))
        XCTAssertEqual(step.line, "click: 2 controls appeared")
        XCTAssertTrue(step.effects.contains("1 navigation"))
        XCTAssertTrue(step.effects.contains("best-effort"))
        XCTAssertTrue(try XCTUnwrap(TrailStep(receipt: receipt, failure: "NO_EFFECT")).line.contains("NO_EFFECT"))
        XCTAssertNil(TrailStep(receipt: [:], failure: nil))
    }
}
