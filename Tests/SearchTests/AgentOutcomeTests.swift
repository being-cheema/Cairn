import CairnProtocol
import XCTest
@testable import Search

/// What an action did, as far as the page showed (ActionOutcome): told to the
/// agent, never changing what is asked or held.
@MainActor
final class AgentOutcomeTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    // MARK: - deciding

    func testANewDocumentIsNavigatedWhateverElseHappened() {
        XCTAssertEqual(ActionOutcome.decide(.init(addressChanged: true, documentReplaced: false, mutations: 5, requests: 2)), .navigated)
        XCTAssertEqual(ActionOutcome.decide(.init(addressChanged: false, documentReplaced: true, mutations: 0, requests: 0)), .navigated)
    }

    func testAChangeInThePageOutranksTheNetwork() {
        XCTAssertEqual(ActionOutcome.decide(.init(addressChanged: false, documentReplaced: false, mutations: 1, requests: 3)), .domMutated)
        XCTAssertEqual(ActionOutcome.decide(.init(addressChanged: false, documentReplaced: false, mutations: 0, requests: 1)), .networkSettled)
        XCTAssertEqual(ActionOutcome.decide(.init(addressChanged: false, documentReplaced: false, mutations: 0, requests: 0)), .noEffect)
    }

    func testTheAnswerSaysItIsBestEffortAndInformsOnly() {
        let said = ActionOutcome.fields(.init(addressChanged: false, documentReplaced: false, mutations: 0, requests: 1))
        XCTAssertEqual(said["outcome"] as? String, "network_settled")
        let note = said["outcome_note"] as? String ?? ""
        XCTAssertTrue(note.contains("best effort"), note)
        XCTAssertTrue(note.contains("400 ms"), note)
        XCTAssertEqual((said["outcome_seen"] as? [String: Int])?["requests"], 1)
    }

    func testWhatThePageSaidIsReadAsNumbersOrNotAtAll() {
        let seen = ActionOutcome.Observation(page: ["mutations": 4, "requests": 2], addressChanged: false)
        XCTAssertEqual(seen, .init(addressChanged: false, documentReplaced: false, mutations: 4, requests: 2))
        // The page's own state gone: the document was replaced.
        XCTAssertTrue(ActionOutcome.Observation(page: ["gone": true], addressChanged: false).documentReplaced)
        // Nonsense from a page is zero, never a huge count.
        XCTAssertEqual(ActionOutcome.Observation(page: ["mutations": -9, "requests": "many"], addressChanged: false).mutations, 0)
        XCTAssertEqual(ActionOutcome.Observation(page: nil, addressChanged: true).documentReplaced, false)
    }

    // MARK: - for real

    private func withServer(_ body: (String) async throws -> Void) async throws {
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <title>Start</title>
                <button onclick="out.textContent = 'added'">Add</button>
                <button onclick="fetch('/ping').then(function () {})">Ping</button>
                <button>Nothing</button>
                <a href="/next">Next</a>
                <label>Name <input id=n></label>
                <label>Pick <select id=p><option>One</option><option>Two</option></select></label>
                <p id=out></p>
                """),
            "/ping": .init(type: "text/plain", body: "pong"),
            "/next": .init(type: "text/html", body: "<title>Next</title><p>there</p>"),
        ])
        defer { server.stop() }
        Store.settings.set(["127.0.0.1"], forKey: "test.agentLocalHosts")
        defer { Store.settings.removeObject(forKey: "test.agentLocalHosts") }
        let browser = Browser()
        Browsers.register(browser)
        defer { Browsers.discard(browser) }
        _ = try XCTUnwrap(AgentControl.shared.sessionForTest(in: browser))
        defer { AgentControl.shared.stopSession() }
        try await body("http://127.0.0.1:\(server.port)/")
    }

    /// Said once, inside the receipt (ActionReceipt), not beside it.
    private func outcome(_ out: [String: Any]) -> String? {
        (out["receipt"] as? [String: Any])?["outcome"] as? String
    }

    private func ask(_ request: [String: Any]) async -> [String: Any] {
        await withCheckedContinuation { done in
            AgentControl.shared.askForTest(request) { done.resume(returning: $0) }
        }
    }

    private func element(_ read: [String: Any], _ name: String) throws -> String {
        let nodes = read["nodes"] as? [[String: Any]] ?? []
        return try XCTUnwrap(nodes.first { $0["name"] as? String == name }?["element"] as? String, "\(name) in \(nodes)")
    }

    func testClickTypeAndPressSayWhatHappened() async throws {
        try await withServer { base in
            let opened = await ask(["do": "open", "url": base])
            let page = try XCTUnwrap(opened["page"] as? String, "\(opened)")
            func read() async -> [String: Any] { await ask(["do": "read", "page": page]) }

            var seen = await read()
            var out = await ask(["do": "click", "element": try element(seen, "Add")])
            XCTAssertEqual(outcome(out), "dom_mutated", "\(out)")

            seen = await read()
            out = await ask(["do": "click", "element": try element(seen, "Ping")])
            XCTAssertEqual(outcome(out), "network_settled", "\(out)")
            XCTAssertNotNil((out["receipt"] as? [String: Any])?["outcome_note"])
            XCTAssertNil(out["outcome"], "said once, in the receipt: \(out)")

            seen = await read()
            out = await ask(["do": "click", "element": try element(seen, "Nothing")])
            XCTAssertEqual(outcome(out), "no_effect", "a dead click: \(out)")

            seen = await read()
            out = await ask(["do": "type", "element": try element(seen, "Name"), "text": "owl"])
            XCTAssertEqual(outcome(out), "no_effect", "typing that nothing answered: \(out)")
            XCTAssertEqual(out["verified"] as? Bool, true, "the typing is checked as before: \(out)")

            out = await ask(["do": "press", "page": page, "key": "Tab"])
            XCTAssertEqual(outcome(out), "no_effect", "\(out)")

            seen = await read()
            out = await ask(["do": "click", "element": try element(seen, "Next")])
            XCTAssertEqual(outcome(out), "navigated", "\(out)")
            XCTAssertEqual(out["navigated"] as? Bool, true)
        }
    }

    func testSelectOptionAnswersWithAReceipt() async throws {
        try await withServer { base in
            let opened = await ask(["do": "open", "url": base])
            let page = try XCTUnwrap(opened["page"] as? String, "\(opened)")
            let seen = await ask(["do": "read", "page": page])
            let out = await ask(["do": "select_option", "element": try XCTUnwrap((seen["nodes"] as? [[String: Any]])?.first { $0["role"] as? String == "combobox" }?["element"] as? String), "value": "Two"])
            XCTAssertNil(out["error"], "\(out)")
            XCTAssertNotNil(out["receipt"] as? [String: Any], "a receipt like click's: \(out)")
        }
    }

    func testAFailedActionHasNoOutcome() async throws {
        try await withServer { base in
            let opened = await ask(["do": "open", "url": base])
            let page = try XCTUnwrap(opened["page"] as? String)
            let out = await ask(["do": "click", "element": "\(page).s99.e0"])
            XCTAssertNotNil(out["error"], "\(out)")
            XCTAssertNil(outcome(out))
        }
    }
}
