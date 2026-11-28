import CairnProtocol
import XCTest
@testable import Search

/// Choosing from a list: a native select, and an ARIA combobox whose options
/// are drawn in a portal, through the clicks the gates see.
@MainActor
final class AgentSelectOptionTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private static let html = """
        <title>Pick</title>
        <label>Size <select id=size><option value=s>Small</option><option value=m>Medium</option>
          <option value=l>Large</option><option value=x disabled>Huge</option></select></label>
        <div id=seen></div>
        <button role=combobox aria-expanded=false aria-label="Colour" id=colour>Pick a colour</button>
        <form onsubmit="return false"><button role=combobox aria-expanded=false aria-label="Send message" id=send>Pick a recipient</button></form>
        <label>Secret <input type=password role=combobox aria-expanded=false value=hunter2></label>
        <script>
          size.addEventListener('change', function () { seen.textContent = 'size=' + size.value; });
          function portal(button, names) {
            button.addEventListener('click', function () {
              if (button.getAttribute('aria-expanded') === 'true') return;
              button.setAttribute('aria-expanded', 'true');
              var ul = document.createElement('ul'); ul.setAttribute('role', 'listbox');
              names.forEach(function (n) {
                var li = document.createElement('li'); li.setAttribute('role', 'option'); li.textContent = n;
                li.style.cssText = 'display:block;padding:6px;cursor:pointer';
                li.addEventListener('click', function () {
                  button.textContent = n; button.setAttribute('aria-expanded', 'false');
                  li.setAttribute('aria-selected', 'true'); ul.remove();
                });
                ul.appendChild(li);
              });
              document.body.appendChild(ul);
            });
          }
          portal(colour, ['Red', 'Green', 'Dark green']);
          portal(send, ['Ann', 'Bo']);
        </script>
        """

    private func withServer(_ body: (String) async throws -> Void) async throws {
        let server = try LocalPageServer(["/": .init(type: "text/html", body: Self.html)])
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

    /// One request, saying no to anything held.
    private func ask(_ request: [String: Any], approve: Bool = false) async throws -> [String: Any] {
        var result: [String: Any]?
        AgentControl.shared.askForTest(request) { result = $0 }
        for _ in 0..<400 where result == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            if AgentControl.shared.session?.held != nil { AgentControl.shared.answerHeldForTest(approve: approve) }
        }
        return try XCTUnwrap(result, "no answer to \(request)")
    }

    private func handle(_ page: String, _ name: String) async throws -> String {
        let read = try await ask(["do": "read", "page": page])
        let nodes = read["nodes"] as? [[String: Any]] ?? []
        return try XCTUnwrap(nodes.first { ($0["name"] as? String ?? "").hasPrefix(name) }?["element"] as? String, "\(name) in \(nodes)")
    }

    private func opened(_ base: String) async throws -> String {
        let out = try await ask(["do": "open", "url": base])
        return try XCTUnwrap(out["page"] as? String, "\(out)")
    }

    private func code(_ out: [String: Any]) -> String? { (out["error"] as? [String: Any])?["code"] as? String }

    func testANativeSelectTakesAnOptionByItsWordsOrItsValueAndFiresChange() async throws {
        try await withServer { base in
            let page = try await opened(base)
            var out = try await ask(["do": "select_option", "element": try await handle(page, "Size"), "value": "medium"])
            XCTAssertEqual(out["selected"] as? String, "Medium", "\(out)")
            XCTAssertEqual(out["verified"] as? Bool, true)
            let read = try await ask(["do": "read", "page": page, "text": true])
            XCTAssertTrue((read["text"] as? String ?? "").contains("size=m"), "the page heard a change")
            out = try await ask(["do": "select_option", "element": try await handle(page, "Size"), "value": "l"])
            XCTAssertEqual(out["selected"] as? String, "Large", "\(out)")
        }
    }

    func testAnOptionThatIsNotThereIsAnErrorWithTheChoicesAndDisabledOnesAreNotTaken() async throws {
        try await withServer { base in
            let page = try await opened(base)
            var out = try await ask(["do": "select_option", "element": try await handle(page, "Size"), "value": "Gigantic"])
            XCTAssertEqual(code(out), "no_such_option", "\(out)")
            let said = (out["error"] as? [String: Any])?["message"] as? String ?? ""
            XCTAssertTrue(said.contains("Small") && said.contains("Large"), said)
            out = try await ask(["do": "select_option", "element": try await handle(page, "Size"), "value": "Huge"])
            XCTAssertEqual(code(out), "disabled", "\(out)")
        }
    }

    func testAPortalComboboxIsOpenedAndItsOptionClicked() async throws {
        try await withServer { base in
            let page = try await opened(base)
            var out = try await ask(["do": "select_option", "element": try await handle(page, "Colour"), "value": "green"], approve: true)
            // "green" is also inside "Dark green": the exact one is taken.
            XCTAssertEqual(out["selected"] as? String, "Green", "\(out)")
            XCTAssertEqual(out["verified"] as? Bool, true, "\(out)")
            let read = try await ask(["do": "read", "page": page])
            XCTAssertTrue((read["nodes"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "Colour" })
            out = try await ask(["do": "select_option", "element": try await handle(page, "Colour"), "value": "Purple"])
            XCTAssertEqual(code(out), "no_such_option", "a closed list is opened again to look: \(out)")
        }
    }

    func testTheGatesStillHoldWhatTheClickToOpenWouldBeHeldFor() async throws {
        try await withServer { base in
            let page = try await opened(base)
            var asked: [AgentGate.Reason] = []
            var result: [String: Any]?
            AgentControl.shared.askForTest(["do": "select_option", "element": try await handle(page, "Send message"), "value": "Ann"]) {
                result = $0
            }
            for _ in 0..<200 where result == nil {
                try await Task.sleep(nanoseconds: 50_000_000)
                if let held = AgentControl.shared.session?.held {
                    asked.append(held.hold.reason)
                    AgentControl.shared.answerHeldForTest(approve: false)
                }
            }
            XCTAssertEqual(asked, [.send])
            XCTAssertNotNil(result?["error"], "\(String(describing: result))")
        }
    }

    func testNeverOnASecretFieldOrAnotherTabsPage() async throws {
        try await withServer { base in
            let page = try await opened(base)
            let out = try await ask(["do": "select_option", "element": try await handle(page, "Secret"), "value": "x"])
            XCTAssertEqual(code(out), "secret_field", "\(out)")
            XCTAssertFalse(String(describing: out).contains("hunter2"))
            let bad = try await ask(["do": "select_option", "element": "p1.s1.e0", "value": ""])
            XCTAssertNotNil(bad["error"])
        }
    }

    func testTheToolPassesOnlyWhatItLists() throws {
        let tool = try XCTUnwrap(MCPTools.all.first { $0.name == "select_option" })
        XCTAssertEqual(tool.verb, .selectOption)
        XCTAssertEqual(Set(tool.passes), ["element", "value"])
        XCTAssertEqual(Set(tool.required), ["element", "value"])
    }
}
