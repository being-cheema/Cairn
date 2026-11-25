import SwiftUI
import XCTest
@testable import Search

/// What the Claude panel says while it works, stops and waits for you,
/// as seen with a real Claude Code: the site in a step, no tool's own name,
/// nothing heard after Stop, and a hold said in the panel as well as on the
/// card, in plain words.
@MainActor
final class ClaudePanelWordsTests: XCTestCase {
    // MARK: steps

    func testASiteOpenedIsNamedByItsHostAlone() {
        XCTAssertEqual(ClaudeCode.describe(tool: "mcp__search__open_tab", input: ["url": "https://www.Example.org/a?b=c"]), "Opening example.org")
        XCTAssertEqual(ClaudeCode.describe(tool: "mcp__search__navigate", input: ["url": "example.com"]), "Going to example.com")
        XCTAssertEqual(ClaudeCode.describe(tool: "mcp__search__open_tab"), "Opening a tab")
        // Never anything but a host's letters, and only for the web.
        XCTAssertEqual(ClaudeCode.describe(tool: "mcp__search__open_tab", input: ["url": "file:///etc/passwd"]), "Opening a tab")
        XCTAssertEqual(ClaudeCode.describe(tool: "mcp__search__open_tab", input: ["url": "https://ex ample.org"]), "Opening a tab")
        XCTAssertEqual(ClaudeCode.describe(tool: "mcp__search__open_tab", input: ["url": 7]), "Opening a tab")
        XCTAssertEqual(ClaudeCode.describe(tool: "mcp__search__read_page", input: ["url": "https://example.org"]), "Reading the page")
    }

    func testDisconnectIsSaidAsWhatItDoes() {
        XCTAssertEqual(ClaudeCode.describe(tool: "mcp__search__disconnect"), "Closing its tabs")
    }

    func testEarlierStepsAreCountedInGoodEnglish() {
        XCTAssertEqual(ClaudePanel.earlier(1), "1 earlier step")
        XCTAssertEqual(ClaudePanel.earlier(3), "3 earlier steps")
    }

    // MARK: held for you

    func testThePanelSaysItWaitsOnlyForItsOwnRunHeldInItsWindow() {
        XCTAssertTrue(PanelHeld<EmptyView>.waiting(panel: true, held: true, here: true))
        XCTAssertFalse(PanelHeld<EmptyView>.waiting(panel: false, held: true, here: true), "another agent's hold is its own card's")
        XCTAssertFalse(PanelHeld<EmptyView>.waiting(panel: true, held: false, here: true))
        XCTAssertFalse(PanelHeld<EmptyView>.waiting(panel: true, held: true, here: false), "another window's")
    }

    func testAMoveToAnotherSiteIsSaidWithTheSiteAndWhereToAnswer() {
        let hold = AgentGate.Hold(reason: .leave, summary: "Leave this task's sites: go to www.example.org", site: "example.org")
        let said = PanelWaiting.say(hold)
        XCTAssertTrue(said.contains("example.org"), said)
        XCTAssertTrue(said.contains("Approve"), said)
        XCTAssertEqual(AgentApproval.title(client: "Claude Code", hold: hold), "“Claude Code” wants to go to another site")
        XCTAssertTrue(AgentApproval.detail(hold).hasPrefix("example.org"))
        XCTAssertFalse(AgentApproval.footnote(hold).contains("quotes"), "there are no quotes to speak of")
    }

    func testOtherHoldsKeepTheBrowsersWordsAndThePagesQuoted() {
        let hold = AgentGate.Hold(reason: .submit, summary: "Submit “Buy now” on shop.example")
        XCTAssertEqual(AgentApproval.detail(hold), hold.summary)
        XCTAssertTrue(AgentApproval.footnote(hold).contains("quotes"))
        XCTAssertFalse(PanelWaiting.say(hold).contains("Buy now"), "the panel never repeats the page's words")
    }

    // MARK: a run

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-words-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func session(reply: String) throws -> ClaudeSession {
        let file = root.appendingPathComponent("fake-claude")
        try Data("#!/bin/sh\necho '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s1\"}'\nwhile read line; do\n\(reply)\ndone\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let script = root.appendingPathComponent("search-mcp")
        try Data("#!/usr/bin/env python3\n".utf8).write(to: script)
        return ClaudeSession(executable: file, verify: { _ in true }, script: script, world: nil)
    }

    private func wait(_ what: String, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(10)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(done(), "waited for: \(what)")
    }

    func testAStepToldAgainWithItsSiteIsSaidAgainInPlace() async throws {
        let session = try session(reply: """
          echo '{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","id":"t1","name":"mcp__search__open_tab"}}}'
          echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__search__open_tab","input":{"url":"https://example.org"}}]}}'
          echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}'
          echo '{"type":"result","is_error":false}'
        """)
        session.draft = "go"; session.submit()
        await wait("the turn to end") { !session.running }
        XCTAssertEqual(session.turns.first?.steps, ["Opening example.org"])
        session.stop()
    }

    func testNothingIsHeardFromARunAfterStop() async throws {
        let session = try session(reply: """
          i=0; while [ $i -lt 4000 ]; do i=$((i+1)); echo "{\\"type\\":\\"assistant\\",\\"message\\":{\\"content\\":[{\\"type\\":\\"tool_use\\",\\"id\\":\\"t$i\\",\\"name\\":\\"mcp__search__click\\"}]}}"; done
          sleep 30
        """)
        session.draft = "go"; session.submit()
        await wait("a step") { (session.turns.first?.steps.count ?? 0) > 0 }
        session.stop()
        let steps = session.turns.first?.steps.count
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(session.turns.first?.steps.count, steps, "a step after Stop would say it went on")
        XCTAssertEqual(session.turns.first?.failed, ClaudeSession.stopped)
    }
}
