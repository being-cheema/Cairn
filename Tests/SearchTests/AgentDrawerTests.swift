import XCTest
@testable import Search

/// Setting an outside agent up, and what the list of trusted ones says.
@MainActor
final class AgentDrawerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private let awkward = "/Users/a b/It's $HOME `x`/Cairn \"2\".app/Contents/MacOS/cairn-mcp"

    /// The shell given the quoted word gives it back, and runs nothing in it.
    func testTheShellTakesThePathWhole() throws {
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/sh")
        run.arguments = ["-c", "printf %s " + AgentSetup.quoted(awkward)]
        let out = Pipe()
        run.standardOutput = out
        try run.run()
        let said = out.fileHandleForReading.readDataToEndOfFile()
        run.waitUntilExit()
        XCTAssertEqual(String(decoding: said, as: UTF8.self), awkward)
    }

    func testTheCommandAndTheJSON() throws {
        let plain = "/Applications/Cairn.app/Contents/MacOS/cairn-mcp"
        XCTAssertEqual(AgentSetup.command(path: plain), "claude mcp add search -- '\(plain)'")
        XCTAssertEqual(AgentSetup.command(path: plain, world: "probe"), "claude mcp add search -- '\(plain)' '--world' 'probe'")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AgentSetup.json(path: awkward).utf8)) as? [String: Any])
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        let search = try XCTUnwrap(servers["search"] as? [String: Any])
        XCTAssertEqual(search["command"] as? String, awkward)
        XCTAssertEqual(search["args"] as? [String], [])
        XCTAssertEqual(Set(search.keys), ["command", "args"], "no environment, so nowhere for a pass")
    }

    func testWhatIsCopiedCarriesNoPass() {
        let copied = AgentSetup.both(path: "/x/cairn-mcp")
        XCTAssertTrue(copied.contains("claude mcp add search -- '/x/cairn-mcp'"))
        XCTAssertTrue(copied.contains("\"mcpServers\""))
        for secret in [ClaudeCode.passVariable, "\"env\"", "--env", "pass"] {
            XCTAssertFalse(copied.lowercased().contains(secret.lowercased()), secret)
        }
        // Before the JSON: comments, a blank line and the command alone.
        let first = copied.components(separatedBy: "# An agent set up")[0].split(separator: "\n")
        XCTAssertEqual(first.filter { !$0.hasPrefix("#") }.count, 1)
    }

    func testATemporaryCopyIsSaidSo() {
        XCTAssertTrue(AgentSetup.passing("/private/var/folders/x/T/AppTranslocation/AB/d/Cairn.app/Contents/MacOS/cairn-mcp"))
        XCTAssertFalse(AgentSetup.passing("/Applications/Cairn.app/Contents/MacOS/cairn-mcp"))
    }

    private func entry(suspended: Bool? = nil, added: Date, used: Date, path: String = "/o/claude", team: String = "TEAM1") -> RememberedAgent {
        RememberedAgent(client: "Claude Code", requirement: "r", team: team, identifier: "com.anthropic.claude-code",
                        signer: "Anthropic PBC", path: path, added: added, used: used, suspended: suspended)
    }

    func testAnEntrySaysEverythingKeptOfIt() {
        let now = Date()
        let lines = AgentEntryWords.lines(entry(added: now, used: now), day: { _ in "D" }, ago: { _ in "A" })
        XCTAssertEqual(lines, [
            "Calls itself “Claude Code”",
            "Signed by Anthropic PBC (com.anthropic.claude-code, team TEAM1)",
            "Last seen at /o/claude",
            "Added D · last used A · until D",
        ])
        let bare = AgentEntryWords.lines(entry(added: now, used: now, path: "", team: ""), day: { _ in "D" }, ago: { _ in "A" })
        XCTAssertEqual(bare.count, 3)
        XCTAssertEqual(AgentEntryWords.state(entry(added: now, used: now), now: now), "Allowed without asking")
        XCTAssertEqual(AgentEntryWords.state(entry(suspended: true, added: now, used: now), now: now), "Asked again since you stopped it")
        let old = now.addingTimeInterval(-40 * 86_400)
        XCTAssertEqual(AgentEntryWords.state(entry(added: old, used: now), now: now), "Run out: asked again next time")
    }

    func testABuildThatCantKeepTrustSaysSo() {
        XCTAssertTrue(AgentEntryWords.nobody(usable: false).contains("can't save lasting permission"))
        XCTAssertFalse(AgentEntryWords.nobody(usable: true).contains("can't"))
    }
}
