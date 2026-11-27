import XCTest
@testable import Search

/// What the panel's Claude spends on a task: the model it runs unless the
/// person picks another, how much one read of a page gives, and what it is
/// told about reading economically.
@MainActor
final class TokenEconomyTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testSonnetUnlessThePersonPicksAnother() {
        let store = Store.settings
        let saved = store.object(forKey: "claude.model")
        defer { if let saved { store.set(saved, forKey: "claude.model") } else { store.removeObject(forKey: "claude.model") } }
        store.removeObject(forKey: "claude.model")
        XCTAssertEqual(Preferences().claudeModel, "sonnet", "nothing picked: Sonnet, not whatever Claude Code defaults to")
        let prefs = Preferences()
        prefs.claudeModel = nil
        XCTAssertNil(Preferences().claudeModel, "Default, once picked, stays picked")
        prefs.claudeModel = "opus"
        XCTAssertEqual(Preferences().claudeModel, "opus")
    }

    func testAPageReadIsSmallUnlessMoreIsAskedFor() {
        XCTAssertEqual(AgentControl.readDefaults.nodes, 150)
        XCTAssertEqual(AgentControl.readDefaults.text, 8000)
    }

    func testItIsToldToReadEconomically() {
        let brief = ClaudeCode.brief()
        for words in ["viewport_only", "diff: true", "text: false", "screenshot"] {
            XCTAssertTrue(brief.contains(words), "the brief says nothing of \(words)")
        }
    }
}

/// What a task cost, shown under its answer.
final class TokenCountTests: XCTestCase {
    func testTheResultSaysHowManyTokensWereUsed() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","usage":{"input_tokens":1200,"cache_creation_input_tokens":3000,"cache_read_input_tokens":40000,"output_tokens":800}}"#
        XCTAssertEqual(ClaudeCode.events(from: line), [.usage(45_000), .done])
        XCTAssertEqual(ClaudeCode.events(from: #"{"type":"result","is_error":false,"usage":{"input_tokens":-5}}"#), [.done],
                       "nothing believable, nothing said")
    }

    func testTheCountIsSaidRoughly() {
        XCTAssertEqual(ClaudePanel.tokens(800), "Used under 1k tokens")
        XCTAssertEqual(ClaudePanel.tokens(45_000), "Used about 45k tokens")
        XCTAssertEqual(ClaudePanel.tokens(1_250_000), "Used about 1.3M tokens")
    }
}
