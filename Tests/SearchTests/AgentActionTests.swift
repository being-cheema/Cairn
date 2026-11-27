import XCTest
@testable import Search

/// Receipts, failure codes, repeats, eids and fill_form, through the same
/// code an agent's requests go through, over this Mac's own page.
@MainActor
final class AgentActionTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func withPage(_ body: (Browser, String) async throws -> Void) async throws {
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <title>Start</title>
                <button id=count onclick="n.textContent = +n.textContent + 1">Count</button>
                <button id=idle>Nothing</button> <button id=send>Send message</button> <span id=n>0</span>
                <form action="/found" method=get><label>Email <input name=email type=email required></label>
                <label>Notes <input name=notes></label><label>Pass <input type=password name=pw></label>
                <button type=submit>Look</button></form>
                <button style="position:absolute;left:10px;top:600px;width:120px;height:30px">Hidden</button>
                <div style="position:absolute;left:0;top:590px;width:400px;height:60px;background:#ccc">cover</div>
                """),
            "/found": .init(type: "text/html", body: "<title>Found</title>"),
        ])
        defer { server.stop() }
        Store.settings.set(["127.0.0.1"], forKey: "test.agentLocalHosts")
        defer { Store.settings.removeObject(forKey: "test.agentLocalHosts") }
        let browser = Browser()
        Browsers.register(browser)
        defer { Browsers.discard(browser) }
        defer { AgentControl.shared.stopSession() }
        XCTAssertNotNil(AgentControl.shared.sessionForTest(in: browser))
        try await body(browser, "http://127.0.0.1:\(server.port)/")
    }

    /// One request as an agent would put it; `approve` answers what is held,
    /// and the reasons held are kept.
    private func ask(_ request: [String: Any], approve: Bool = true, held: ((AgentGate.Reason) -> Void)? = nil) async throws -> [String: Any] {
        var result: [String: Any]?
        AgentControl.shared.askForTest(request) { result = $0 }
        for _ in 0..<600 where result == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let hold = AgentControl.shared.session?.held {
                held?(hold.hold.reason)
                AgentControl.shared.answerHeldForTest(approve: approve)
            }
        }
        return try XCTUnwrap(result, "no answer to \(request)")
    }

    private func failure(_ out: [String: Any]) -> String? { (out["failure"] as? [String: Any])?["code"] as? String }

    private func start(_ base: String) async throws -> (String, [String: String]) {
        let opened = try await ask(["do": "open", "url": base])
        let page = try XCTUnwrap(opened["page"] as? String, "\(opened)")
        let read = try await ask(["do": "read", "page": page])
        var eids: [String: String] = [:]
        for node in read["nodes"] as? [[String: Any]] ?? [] {
            if let name = node["name"] as? String, let eid = node["eid"] as? String { eids[name] = eid }
        }
        return (page, eids)
    }

    func testAClickReturnsAReceiptAndAnIdleOneSaysNoEffect() async throws {
        try await withPage { _, base in
            let (page, eids) = try await start(base)
            XCTAssertNotNil(eids["Count"])
            var out = try await ask(["do": "click", "page": page, "eid": try XCTUnwrap(eids["Count"])])
            let receipt = try XCTUnwrap(out["receipt"] as? [String: Any], "\(out)")
            XCTAssertEqual(receipt["eid"] as? String, eids["Count"])
            XCTAssertNotEqual(receipt["before_hash"] as? String, receipt["after_hash"] as? String)
            XCTAssertNil(out["failure"], "\(out)")
            out = try await ask(["do": "click", "page": page, "eid": try XCTUnwrap(eids["Nothing"])])
            XCTAssertEqual(failure(out), "NO_EFFECT", "\(out)")
            XCTAssertNotNil((out["failure"] as? [String: Any])?["heuristic"])
        }
    }

    func testTheSameClickOnAPageThatHasntMovedIsHeldNotDropped() async throws {
        try await withPage { _, base in
            let (page, eids) = try await start(base)
            let count = try XCTUnwrap(eids["Count"])
            _ = try await ask(["do": "click", "page": page, "eid": count])
            var reasons: [AgentGate.Reason] = []
            var out = try await ask(["do": "click", "page": page, "eid": count], approve: false) { reasons.append($0) }
            XCTAssertEqual(reasons, [.repeatAction])
            XCTAssertEqual((out["error"] as? [String: Any])?["code"] as? String, "declined", "\(out)")
            reasons = []
            out = try await ask(["do": "click", "page": page, "eid": count]) { reasons.append($0) }
            XCTAssertEqual(reasons, [.repeatAction])
            XCTAssertNotNil(out["receipt"], "allowed by the person's click: it is done")
        }
    }

    func testACoveredControlIsOccludedAndSaysSo() async throws {
        try await withPage { _, base in
            let (page, eids) = try await start(base)
            let out = try await ask(["do": "click", "page": page, "eid": try XCTUnwrap(eids["Hidden"])])
            let error = try XCTUnwrap(out["error"] as? [String: Any], "\(out)")
            XCTAssertEqual(error["failure"] as? String, "OCCLUDED")
            XCTAssertEqual(error["code"] as? String, "obscured")
        }
    }

    func testTheFormsOwnCheckBlocksAndNamesTheField() async throws {
        try await withPage { _, base in
            let (page, eids) = try await start(base)
            let out = try await ask(["do": "click", "page": page, "eid": try XCTUnwrap(eids["Look"])])
            XCTAssertEqual(failure(out), "VALIDATION_BLOCKED", "\(out)")
            let fields = (out["failure"] as? [String: Any])?["fields"] as? [[String: Any]]
            XCTAssertEqual(fields?.first?["eid"] as? String, eids["Email"])
        }
    }

    func testFillFormFillsReportsAndNeverTouchesASecret() async throws {
        try await withPage { _, base in
            let (page, eids) = try await start(base)
            let email = try XCTUnwrap(eids["Email"]), pass = try XCTUnwrap(eids["Pass"])
            var out = try await ask(["do": "fill_form", "page": page,
                                     "fields": [["eid": email, "value": "ada@example.org"], ["eid": pass, "value": "x"]]])
            XCTAssertEqual((out["error"] as? [String: Any])?["code"] as? String, "secret_field", "\(out)")
            out = try await ask(["do": "fill_form", "page": page, "fields": [["eid": email, "value": "ada@example.org"]]])
            XCTAssertEqual(out["filled"] as? Int, 1, "\(out)")
            XCTAssertEqual((out["validation"] as? [String: Any])?["all_valid"] as? Bool, true)
            XCTAssertNotNil(out["receipt"])
            let read = try await ask(["do": "read", "page": page])
            let node = (read["nodes"] as? [[String: Any]])?.first { $0["name"] as? String == "Email" }
            XCTAssertEqual(node?["value"] as? String, "ada@example.org")
        }
    }

    func testAnEidFromBeforeTheLastReadStillNamesTheControl() async throws {
        try await withPage { _, base in
            let (page, eids) = try await start(base)
            _ = try await ask(["do": "read", "page": page])
            let out = try await ask(["do": "click", "page": page, "eid": try XCTUnwrap(eids["Count"])])
            XCTAssertNotNil(out["receipt"], "\(out)")
        }
    }

    func testARunThatGoesRoundInCirclesIsStoppedByTheBrowser() async throws {
        LoopLimits(actions: 100, stalled: 2, identical: 9, minutes: 30).save()
        defer { for key in LoopLimits.keys.values { Store.settings.removeObject(forKey: key) } }
        try await withPage { _, base in
            let (page, eids) = try await start(base)
            let idle = try XCTUnwrap(eids["Nothing"])
            var out: [String: Any] = [:]
            for _ in 0..<2 { out = try await ask(["do": "click", "page": page, "eid": idle]) }
            XCTAssertNotNil(out["loop_suspected"], "\(out)")
            out = try await ask(["do": "click", "page": page, "eid": idle])
            let error = try XCTUnwrap(out["error"] as? [String: Any], "\(out)")
            XCTAssertEqual(error["code"] as? String, "LOOP_SUSPECTED")
            XCTAssertNotNil(error["trace"])
            out = try await ask(["do": "read", "page": page])
            XCTAssertEqual((out["error"] as? [String: Any])?["code"] as? String, "LOOP_SUSPECTED", "reads stop too")
        }
    }

    func testADisambiguationIsAnsweredOnlyByAClickOnABadge() async throws {
        try await withPage { _, base in
            let (page, eids) = try await start(base)
            let (count, idle) = (try XCTUnwrap(eids["Count"]), try XCTUnwrap(eids["Nothing"]))
            var result: [String: Any]?
            AgentControl.shared.askForTest(["do": "disambiguate", "page": page, "eids": [count, idle],
                                            "prompt": "Which of these is the one to press?"]) { result = $0 }
            for _ in 0..<200 where AgentControl.shared.session?.held == nil { try await Task.sleep(nanoseconds: 50_000_000) }
            let held = try XCTUnwrap(AgentControl.shared.session?.held, "\(String(describing: result))")
            XCTAssertEqual(held.hold.reason, .choose)
            XCTAssertEqual(held.hold.intent, "Which of these is the one to press?")
            let view = try XCTUnwrap(AgentControl.shared.choosingForTest)
            XCTAssertEqual(view.badges.map(\.number), [1, 2])
            AgentControl.shared.choose(number: 1, event: nil, on: view.badges[0])
            AgentControl.shared.answerHeld(approve: true, event: nil)
            XCTAssertNil(result, "no event, no answer")
            AgentControl.shared.chooseForTest(number: 2)
            for _ in 0..<100 where result == nil { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertEqual(result?["chosen"] as? String, idle)
            XCTAssertEqual(result?["number"] as? Int, 2)
            XCTAssertNil(AgentControl.shared.choosingForTest, "the badges go")
        }
    }

    func testPickingNoneIsSaidAndTooFewOrManyIsRefused() async throws {
        try await withPage { _, base in
            let (page, eids) = try await start(base)
            let (count, idle) = (try XCTUnwrap(eids["Count"]), try XCTUnwrap(eids["Nothing"]))
            var out = try await ask(["do": "disambiguate", "page": page, "eids": [count], "prompt": "x"])
            XCTAssertEqual((out["error"] as? [String: Any])?["code"] as? String, "bad_eids")
            out = try await ask(["do": "disambiguate", "page": page, "eids": [count, idle], "prompt": "Which?"], approve: false)
            XCTAssertEqual((out["error"] as? [String: Any])?["code"] as? String, "declined", "\(out)")
        }
    }

    func testTheIntentIsShownAsTheAgentsWordsOnTheQuestion() async throws {
        try await withPage { _, base in
            let (page, eids) = try await start(base)
            var seen: String?
            let out = try await ask(["do": "click", "page": page, "eid": try XCTUnwrap(eids["Send message"]),
                                     "intent": "Tell Ada\nthe news"], approve: false) { _ in
                seen = AgentControl.shared.session?.held?.hold.intent
            }
            XCTAssertEqual(seen, "Tell Ada the news")
            XCTAssertEqual((out["error"] as? [String: Any])?["code"] as? String, "declined")
        }
    }

    func testAnIntentIsOneShortPrintableLine() {
        XCTAssertNil(AgentGate.intentLine(nil))
        XCTAssertNil(AgentGate.intentLine("  \n "))
        XCTAssertEqual(AgentGate.intentLine("a\u{0}b\n c"), "a b c")
        XCTAssertEqual(AgentGate.intentLine(String(repeating: "x", count: 500))?.count, 141)
    }

    func testAReadSaysWhatKindOfPageItIsAndWhereItsWordsCameFrom() async throws {
        try await withPage { _, base in
            let (page, eids) = try await start(base)
            let read = try await ask(["do": "read", "page": page, "budget_tokens": 120])
            let kind = try XCTUnwrap(read["archetype"] as? [String: Any], "\(read)")
            XCTAssertEqual(kind["type"] as? String, "login")
            XCTAssertLessThanOrEqual(ArchetypeBudget.tokens(kind), 120)
            XCTAssertEqual((read["sources"] as? [String: Any])?["text"] != nil, true)
            let zoomed = try await ask(["do": "zoom", "page": page, "eid": try XCTUnwrap(eids["Email"]), "budget_tokens": 300])
            XCTAssertNotNil(zoomed["controls"], "\(zoomed)")
            XCTAssertNotNil(zoomed["untrusted"])
        }
    }
}
