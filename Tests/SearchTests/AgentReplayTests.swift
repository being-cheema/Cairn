import CairnProtocol
import XCTest
@testable import Search

/// Fast Macros: what may be kept, what counts as the same control, and real
/// replays over this Mac's own pages, through the same code a live agent's
/// requests go through.
@MainActor
final class AgentReplayTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func click(_ name: String, on host: String = "127.0.0.1") -> MacroStep {
        MacroStep(kind: .click, tab: 0, host: host, role: "button", name: name)
    }

    private func type(_ text: String, into name: String) -> MacroStep {
        MacroStep(kind: .type, tab: 0, host: "127.0.0.1", role: "textbox", name: name, text: text)
    }

    // MARK: - what may be kept

    func testNothingSecretIsKept() {
        XCTAssertNil(MacroRules.refusal(type("red shoes", into: "Search")))
        XCTAssertNotNil(MacroRules.refusal(type("4111 1111 1111 1111", into: "Search")))
        XCTAssertNotNil(MacroRules.refusal(type("password is hunter2", into: "Notes")))
        XCTAssertNotNil(MacroRules.refusal(MacroStep(kind: .open, tab: 0, url: "https://example.com/?token=abc123")))
        XCTAssertNotNil(MacroRules.refusal(MacroStep(kind: .open, tab: 0, url: "file:///etc/passwd")))
        XCTAssertNil(MacroRules.refusal(MacroStep(kind: .press, tab: 0, host: "a", key: "Enter")))
        XCTAssertNotNil(MacroRules.refusal(MacroStep(kind: .press, tab: 0, host: "a", key: "x")))
        XCTAssertNotNil(MacroRules.refusal(click("")))
    }

    func testARecorderSpoiledKeepsNothing() {
        let tab = UUID()
        var recorder = MacroRecorder()
        recorder.took(MacroStep(kind: .open, tab: 0, url: "https://example.com/"), on: tab)
        recorder.took(click("Go"), on: tab)
        XCTAssertEqual(recorder.steps.count, 2)
        recorder.took(click("Go"), on: UUID())
        XCTAssertEqual(recorder.spoiled, "it used a tab this message didn't open")
        XCTAssertTrue(recorder.steps.isEmpty)
        recorder.took(MacroStep(kind: .open, tab: 0, url: "https://example.com/"), on: tab)
        XCTAssertTrue(recorder.steps.isEmpty)
    }

    func testOnlyACompletedTaskBecomesOneAndAFileIsCheckedAgain() throws {
        var recorder = MacroRecorder()
        recorder.took(MacroStep(kind: .open, tab: 0, url: "https://example.com/"), on: UUID())
        var record = TaskRecord(prompt: "find shoes", model: nil)
        XCTAssertNotNil(MacroStore.macro(from: record, recorder))
        record.outcome = .stopped
        XCTAssertNil(MacroStore.macro(from: record, recorder))
        record.outcome = .completed
        let macro = try XCTUnwrap(MacroStore.macro(from: record, recorder))
        let folder = Store.file("Macros-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(MacroStore.save(macro, in: folder))
        let saved = try XCTUnwrap(MacroStore.all(in: folder).first)
        XCTAssertEqual(saved.steps, macro.steps)
        let file = folder.appendingPathComponent("\(macro.id.uuidString).json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        // Edited by hand into something that may not be played: passed over.
        let edited = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "https:", with: "file:")
        try Data(edited.utf8).write(to: file)
        XCTAssertTrue(MacroStore.all(in: folder).isEmpty)
    }

    func testAnAnchorIsOneControlOrNone() {
        let node: [String: Any] = ["role": "button", "name": "Next", "element": "p1.s1.e0"]
        XCTAssertEqual(MacroRules.anchor(click("Next"), among: [node]), .found("p1.s1.e0"))
        for nodes in [[], [node, node], [["role": "link", "name": "Next", "element": "x"]],
                      [["role": "button", "name": "Next", "element": "x", "disabled": true]]] as [[[String: Any]]] {
            guard case .mismatch = MacroRules.anchor(click("Next"), among: nodes) else { return XCTFail("\(nodes)") }
        }
        let secret: [String: Any] = ["role": "textbox", "name": "Code", "element": "x", "redacted": true]
        guard case .mismatch = MacroRules.anchor(type("1", into: "Code"), among: [secret]) else { return XCTFail() }
    }

    // MARK: - real replays

    private func withServer(_ body: (Browser, String) async throws -> Void) async throws {
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <title>Start</title>
                <label>Search <input id=q></label>
                <button onclick="document.title='Found ' + q.value; out.textContent='results for ' + q.value">Look</button>
                <form method=post action="/sent"><input name=note aria-label=Note><button>Send message</button></form>
                <label>Code <input type=password></label>
                <p id=out></p>
                """),
            "/sent": .init(type: "text/html", body: "<title>Sent</title>"),
        ])
        defer { server.stop() }
        Store.settings.set(["127.0.0.1"], forKey: "test.agentLocalHosts")
        defer { Store.settings.removeObject(forKey: "test.agentLocalHosts") }
        let browser = Browser()
        Browsers.register(browser)
        defer { Browsers.discard(browser) }
        defer { AgentControl.shared.stopSession() }
        try await body(browser, "http://127.0.0.1:\(server.port)/")
        XCTAssertFalse(server.requests.contains("/sent"), "nothing was sent")
    }

    private func macro(_ base: String, _ steps: [MacroStep]) -> FastMacro {
        FastMacro(name: "t", prompt: "t", steps: [MacroStep(kind: .open, tab: 0, url: base)] + steps)
    }

    /// Plays it, saying no to whatever is held for a click.
    private func play(_ macro: FastMacro, in browser: Browser) async throws -> (AgentControl.Replayed, [AgentGate.Reason]) {
        var result: AgentControl.Replayed?
        XCTAssertNil(AgentControl.shared.replayForTest(macro, in: browser) { result = $0 })
        var asked: [AgentGate.Reason] = []
        for _ in 0..<600 where result == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let held = AgentControl.shared.session?.held {
                asked.append(held.hold.reason)
                AgentControl.shared.answerHeldForTest(approve: false)
            }
        }
        return (try XCTUnwrap(result, "the replay never ended"), asked)
    }

    func testAReplayDoesTheStepsAndHandsBackTheLastPage() async throws {
        try await withServer { browser, base in
            let (result, asked) = try await play(macro(base, [type("owls", into: "Search"), click("Look")]), in: browser)
            guard case .finished(let page) = result else { return XCTFail("\(result)") }
            XCTAssertTrue(page.contains("results for owls"), page)
            XCTAssertEqual(asked, [])
            XCTAssertNil(AgentControl.shared.session)
            XCTAssertTrue(browser.tabs.contains { $0.agent && !$0.store.isPersistent })
        }
    }

    func testAReplayStopsAtTheFirstThingThatIsNotThere() async throws {
        try await withServer { browser, base in
            let (result, _) = try await play(macro(base, [click("Gone"), click("Look")]), in: browser)
            guard case .stopped(let why) = result else { return XCTFail("\(result)") }
            XCTAssertTrue(why.contains("Gone"), why)
        }
    }

    func testAReplayNeverTypesIntoASecretField() async throws {
        try await withServer { browser, base in
            let (result, _) = try await play(macro(base, [type("owls", into: "Code")]), in: browser)
            guard case .stopped(let why) = result else { return XCTFail("\(result)") }
            XCTAssertTrue(why.contains("secret"), why)
        }
    }

    func testAReplayIsHeldAtTheSameGatesAndANoEndsIt() async throws {
        try await withServer { browser, base in
            let (result, asked) = try await play(macro(base, [click("Send message"), click("Look")]), in: browser)
            XCTAssertEqual(asked, [.send])
            guard case .stopped = result else { return XCTFail("\(result)") }
        }
    }

    func testOnlyYourOwnClickStartsOne() throws {
        let browser = Browser()
        let why = AgentControl.shared.startReplay(macro("https://example.com/", []), in: browser, event: nil, on: nil, shownAt: 0) { _ in
            XCTFail("it ran")
        }
        XCTAssertNotNil(why)
        XCTAssertNil(AgentControl.shared.session)
        XCTAssertNil(AgentVerb(rawValue: "replay"))
    }
}
