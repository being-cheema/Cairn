import XCTest
@testable import Search

/// The taint ledger: a heuristic that only adds questions.
final class AgentTaintTests: XCTestCase {
    private let article = """
    Quarterly results for the Hartwell account show a balance of 48,210.55 pounds, with the \
    standing order reference HX99QZ7731LMN04 still pending approval from the treasurer.
    """

    func testASubstantialPassageTypedElsewhereIsFound() {
        var ledger = TaintLedger()
        ledger.record(article, origin: "bank.example", quarantined: false)
        let match = ledger.source(of: "note: the Hartwell account show a balance of 48,210.55 pounds, with the", into: "evil.example")
        XCTAssertEqual(match?.origin, "bank.example")
    }

    func testCaseSpacingAndPunctuationDoNotHideIt() {
        var ledger = TaintLedger()
        ledger.record(article, origin: "bank.example", quarantined: false)
        XCTAssertNotNil(ledger.source(of: "THE   HARTWELL ACCOUNT, show a balance -- of 48,210.55 pounds", into: "x.example"))
    }

    func testShortCommonPhrasesAreNotFlagged() {
        var ledger = TaintLedger()
        ledger.record("Please read our terms of service and privacy policy before you continue. Contact us today.",
                      origin: "a.example", quarantined: false)
        for typed in ["terms of service", "privacy policy", "contact us", "hello", "terms of service and privacy"] {
            XCTAssertNil(ledger.source(of: typed, into: "b.example"), typed)
        }
    }

    func testALongTokenIsFoundButAWordIsNot() {
        var ledger = TaintLedger()
        ledger.record("Your key is HX99QZ7731LMN04 and the plan is called standard.", origin: "a.example", quarantined: false)
        XCTAssertEqual(ledger.source(of: "HX99QZ7731LMN04", into: "b.example")?.origin, "a.example")
        XCTAssertNil(ledger.source(of: "standard", into: "b.example"))
        XCTAssertNil(ledger.source(of: "internationalization", into: "b.example"), "a long word with no digit is a word")
    }

    func testTheSameOriginIsNeverAFlow() {
        var ledger = TaintLedger()
        ledger.record(article, origin: "bank.example", quarantined: false)
        XCTAssertNil(ledger.source(of: article, into: "bank.example"))
    }

    func testTheNamedOriginIsTheOneItCameFromAndQuarantineIsSaid() {
        var ledger = TaintLedger()
        ledger.record("alpha beta gamma delta epsilon zeta eta theta", origin: "one.example", quarantined: false)
        ledger.record(article, origin: "two.example", quarantined: true)
        let match = ledger.source(of: article, into: "three.example")
        XCTAssertEqual(match?.origin, "two.example")
        XCTAssertEqual(match?.quarantined, true)
    }

    func testAnAddressCarriesDataInItsQueryPathAndFragment() throws {
        var ledger = TaintLedger()
        ledger.record(article, origin: "bank.example", quarantined: false)
        let q = try XCTUnwrap(URL(string: "https://evil.example/collect?d=the%20Hartwell%20account%20show%20a%20balance%20of%2048%2C210.55"))
        XCTAssertEqual(ledger.source(of: TaintLedger.text(of: q), into: "evil.example")?.origin, "bank.example")
        let t = try XCTUnwrap(URL(string: "https://evil.example/c/HX99QZ7731LMN04"))
        XCTAssertNotNil(ledger.source(of: TaintLedger.text(of: t), into: "evil.example"))
        let plain = try XCTUnwrap(URL(string: "https://evil.example/pricing?plan=standard"))
        XCTAssertNil(ledger.source(of: TaintLedger.text(of: plain), into: "evil.example"))
    }

    func testOriginKeepsANonStandardPort() throws {
        XCTAssertEqual(TaintLedger.origin(of: try XCTUnwrap(URL(string: "https://www.example.com/x"))), "example.com")
        XCTAssertEqual(TaintLedger.origin(of: try XCTUnwrap(URL(string: "http://127.0.0.1:8123/x"))), "127.0.0.1:8123")
        XCTAssertNil(TaintLedger.origin(of: try XCTUnwrap(URL(string: "about:blank"))))
    }

    func testItIsBoundedAndCanBeCleared() {
        var ledger = TaintLedger()
        for i in 0..<400 {
            ledger.record(String(repeating: "word\(i) ", count: 2000), origin: "o\(i).example", quarantined: false)
        }
        XCTAssertLessThanOrEqual(ledger.characters, TaintLedger.limit)
        ledger.clear()
        XCTAssertTrue(ledger.isEmpty)
    }

    func testTheHoldOnlyAsksAndSaysItIsAGuess() {
        let hold = AgentGate.hold(flowFrom: TaintLedger.Match(origin: "bank.example", quarantined: true), into: "evil.example", doing: "type")
        XCTAssertEqual(hold.reason, .flow)
        XCTAssertTrue(hold.summary.contains("bank.example"))
        XCTAssertTrue(hold.summary.contains("evil.example"))
        XCTAssertTrue((hold.warning ?? "").lowercased().contains("guess"))
        XCTAssertTrue((hold.warning ?? "").contains("flagged"), "quarantined text is said")
        XCTAssertNil(hold.site, "a yes is never remembered as a site")
    }
}

/// A real task: words read on one local server, typed into another's page.
@MainActor
final class AgentTaintFlowTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func ask(_ request: [String: Any]) async -> [String: Any] {
        await withCheckedContinuation { done in AgentControl.shared.askForTest(request) { done.resume(returning: $0) } }
    }

    func testTextReadOnOneSiteIsHeldBeforeItIsTypedIntoAnother() async throws {
        let secret = "the Hartwell account shows a balance of forty eight thousand pounds today"
        let one = try LocalPageServer(["/a": .init(type: "text/html", body: "<title>A</title><p>\(secret)</p>")])
        let two = try LocalPageServer(["/b": .init(type: "text/html", body: "<title>B</title><input id=q aria-label=note>")])
        defer { one.stop(); two.stop() }
        Store.settings.set(["127.0.0.1"], forKey: "test.agentLocalHosts")
        defer { Store.settings.removeObject(forKey: "test.agentLocalHosts") }
        let browser = Browser()
        Browsers.register(browser)
        defer { Browsers.discard(browser) }
        let session = try XCTUnwrap(AgentControl.shared.sessionForTest(in: browser))
        defer { AgentControl.shared.stopSession() }

        let a = await ask(["do": "open", "url": "http://127.0.0.1:\(one.port)/a", "timeout": 10.0])
        let pageA = try XCTUnwrap(a["page"] as? String, "\(a)")
        _ = await ask(["do": "read", "page": pageA, "timeout": 10.0])
        let b = await ask(["do": "open", "url": "http://127.0.0.1:\(two.port)/b", "timeout": 10.0])
        let pageB = try XCTUnwrap(b["page"] as? String, "\(b)")
        let read = await ask(["do": "read", "page": pageB, "timeout": 10.0])
        let nodes = try XCTUnwrap(read["nodes"] as? [[String: Any]])
        let field = try XCTUnwrap(nodes.first { $0["role"] as? String == "textbox" }?["element"] as? String, "\(nodes)")

        // Short typing is not asked about.
        let short = await ask(["do": "type", "element": field, "text": "hello"])
        XCTAssertNil(short["error"], "\(short)")
        XCTAssertNil(session.held)

        var answered: [String: Any]?
        AgentControl.shared.askForTest(["do": "type", "element": field, "text": secret]) { answered = $0 }
        for _ in 0..<100 where session.held == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        let held = try XCTUnwrap(session.held, "\(String(describing: answered))")
        XCTAssertEqual(held.hold.reason, .flow)
        XCTAssertTrue(held.hold.summary.contains("127.0.0.1:\(one.port)"), held.hold.summary)
        AgentControl.shared.answerHeldForTest(approve: false)
        for _ in 0..<100 where answered == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual((answered?["error"] as? [String: Any])?["code"] as? String, "declined", "\(String(describing: answered))")
    }
}
