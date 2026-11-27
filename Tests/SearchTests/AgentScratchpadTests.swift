import CairnProtocol
import XCTest
@testable import Search

/// The Task Scratchpad: the agent's notes shown to the person as data, and the
/// person's own, handed to the agent once, in its next answer.
@MainActor
final class AgentScratchpadTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testTheAgentWritesAndAppendsWithinALimit() {
        var pad = Scratchpad()
        XCTAssertTrue(pad.write("plan A", append: false))
        XCTAssertTrue(pad.write("then B", append: true))
        XCTAssertEqual(pad.agent, "plan A\nthen B")
        XCTAssertTrue(pad.write("fresh", append: false))
        XCTAssertEqual(pad.agent, "fresh")
        XCTAssertFalse(pad.write(String(repeating: "x", count: Scratchpad.agentMost + 1), append: false), "too long: nothing is taken")
        XCTAssertEqual(pad.agent, "fresh")
    }

    func testThePersonsEditsGoToTheAgentOnceAndAreMarkedAsTheirs() throws {
        var pad = Scratchpad()
        XCTAssertNil(pad.takeEdits(), "nothing written, nothing said")
        pad.mine = "skip the second shop"
        let said = try XCTUnwrap(pad.takeEdits())
        XCTAssertEqual(said["text"] as? String, "skip the second shop")
        XCTAssertTrue((said["from"] as? String ?? "").contains("person"))
        XCTAssertNil(pad.takeEdits(), "once")
        pad.mine = "skip the second shop, and the third"
        XCTAssertNotNil(pad.takeEdits())
        pad.mine = ""
        XCTAssertEqual(pad.takeEdits()?["text"] as? String, "", "taking a note back is told too")
    }

    func testTheirBoxIsKeptWithinItsLimitAndEndsWithTheTask() {
        var pad = Scratchpad()
        pad.mine = String(repeating: "y", count: Scratchpad.mineMost + 50)
        XCTAssertEqual(pad.mine.count, Scratchpad.mineMost)
        pad.clear()
        XCTAssertEqual(pad, Scratchpad())
    }

    func testTheToolIsForThePanelsOwnRunAndPassesOnlyWhatItLists() throws {
        let tool = try XCTUnwrap(MCPTools.all.first { $0.name == "update_scratchpad" })
        XCTAssertEqual(tool.verb, .updateScratchpad)
        XCTAssertEqual(Set(tool.passes), ["text", "append"])
        XCTAssertEqual(tool.required, ["text"])
    }

    private func ask(_ request: [String: Any]) async -> [String: Any] {
        await withCheckedContinuation { done in
            AgentControl.shared.askForTest(request) { done.resume(returning: $0) }
        }
    }

    func testAnotherProgramHasNoScratchpad() async throws {
        let browser = Browser()
        Browsers.register(browser)
        defer { Browsers.discard(browser) }
        _ = try XCTUnwrap(AgentControl.shared.sessionForTest(in: browser))
        defer { AgentControl.shared.stopSession() }
        let out = await ask(["do": "update_scratchpad", "text": "hi"])
        XCTAssertEqual((out["error"] as? [String: Any])?["code"] as? String, "no_panel", "\(out)")
    }

    func testInARunTheNotesAreShownAndTheEditsComeBackInTheNextAnswer() async throws {
        let browser = Browser()
        Browsers.register(browser)
        defer { Browsers.discard(browser) }
        _ = try XCTUnwrap(AgentControl.shared.sessionForTest(in: browser, panel: true))
        defer { AgentControl.shared.stopSession() }
        var out = await ask(["do": "update_scratchpad", "text": "Plan: compare three shops"])
        XCTAssertEqual(out["saved"] as? Bool, true, "\(out)")
        XCTAssertEqual(browser.claude.scratchpad.agent, "Plan: compare three shops")
        XCTAssertNil(out["user_notes"])
        browser.claude.editScratchpad("Not the blue one")
        out = await ask(["do": "status"])
        let notes = try XCTUnwrap(out["user_notes"] as? [String: Any], "\(out)")
        XCTAssertEqual(notes["text"] as? String, "Not the blue one")
        out = await ask(["do": "status"])
        XCTAssertNil(out["user_notes"])
        // Their words are the person's, never taken for a page's: no fence is put round them.
        XCTAssertFalse(String(describing: notes).contains(Quarantine.opening))
        browser.claude.newChat()
        XCTAssertEqual(browser.claude.scratchpad, Scratchpad(), "it ends with the task")
    }
}
