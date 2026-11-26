import AppKit
import WebKit
import XCTest
import CairnProtocol
@testable import Search

/// Coding agents (AgentControl): the question's rules, what may be read and
/// where an agent may go, what a page's secret fields give back, and the
/// socket's permissions. Pages are laid out in the bench's room, off every
/// screen; nothing is shown.
@MainActor
final class AgentControlTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// The room the pages were laid out in goes back off the window list:
    /// later tests count every window ordered in as one shown.
    override func tearDown() {
        PageRoom.shared.window?.orderOut(nil)
        super.tearDown()
    }

    // MARK: - consent

    func testNothingBeforeHelloAndNothingWhileAsking() {
        var consent = AgentConsent()
        XCTAssertEqual(consent.verdict(for: "hello"), .go)
        XCTAssertEqual(consent.verdict(for: "open"), .refuse("hello_first"))
        XCTAssertTrue(consent.hello())
        XCTAssertFalse(consent.hello(), "the question goes up once")
        XCTAssertEqual(consent.state, .asking)
        for verb in ["open", "tabs", "read", "click", "shot"] {
            XCTAssertEqual(consent.verdict(for: verb), .wait, verb)
        }
        XCTAssertFalse(consent.may(.read, own: true))
    }

    func testAllowedWithoutTabs() {
        var consent = AgentConsent()
        consent.hello()
        consent.answer(allow: true, seesTabs: false)
        XCTAssertEqual(consent.state, .allowed)
        XCTAssertEqual(consent.verdict(for: "open"), .go)
        XCTAssertEqual(consent.verdict(for: "hello"), .refuse("said_hello"))
        XCTAssertTrue(consent.may(.read, own: true))
        XCTAssertTrue(consent.may(.drive, own: true))
        XCTAssertFalse(consent.may(.read, own: false), "your tabs only if you said so")
        XCTAssertFalse(consent.may(.drive, own: false))
    }

    func testSeeingYourTabsIsNeverUsingThem() {
        var consent = AgentConsent()
        consent.hello()
        consent.answer(allow: true, seesTabs: true)
        XCTAssertTrue(consent.may(.read, own: false))
        XCTAssertFalse(consent.may(.drive, own: false))
    }

    func testRefusedAndEndedAreFinal() {
        var refused = AgentConsent()
        refused.hello()
        refused.answer(allow: false, seesTabs: true)
        XCTAssertEqual(refused.state, .refused)
        XCTAssertFalse(refused.seesTabs)
        XCTAssertEqual(refused.verdict(for: "open"), .refuse("not_allowed"))
        refused.answer(allow: true, seesTabs: true)
        XCTAssertEqual(refused.state, .refused, "no second answer")

        var ended = AgentConsent()
        ended.hello()
        ended.answer(allow: true, seesTabs: true)
        ended.end()
        XCTAssertEqual(ended.state, .ended)
        XCTAssertEqual(ended.verdict(for: "tabs"), .refuse("stopped"))
        XCTAssertFalse(ended.may(.read, own: true))
        ended.answer(allow: true, seesTabs: true)
        XCTAssertEqual(ended.state, .ended)

        var early = AgentConsent()
        early.answer(allow: true, seesTabs: false)
        XCTAssertEqual(early.state, .connected, "no answer to a question that isn't up")
    }

    // MARK: - addresses

    func testOnlyTheWeb() {
        XCTAssertEqual(AgentRules.address("https://example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertEqual(AgentRules.address("http://example.com:8080/")?.port, 8080)
        XCTAssertNil(AgentRules.address("http://127.0.0.1:8080/"), "this Mac: AgentNetworkTests")
        XCTAssertEqual(AgentRules.address("example.com")?.absoluteString, "https://example.com")
        for refused in ["file:///etc/passwd", "search://settings", "search://passwords", "javascript:alert(1)",
                        "data:text/html,hi", "about:blank", "webkit-extension://abc/popup.html",
                        "chrome-extension://abc/x", "mailto:a@b.c", "tel:123", "ftp://example.com/",
                        "https://user:pass@example.com/", "https://", "", "two words", "FILE:///tmp"] {
            XCTAssertNil(AgentRules.address(refused), refused)
        }
        XCTAssertNil(AgentRules.address(InternalPage.scheme + "://settings"))
    }

    func testWhereItsPagesMayGoByThemselves() {
        for allowed in ["https://a.com", "http://a.com", "about:blank", "blob:https://a.com/x", "data:text/plain,x"] {
            XCTAssertTrue(AgentRules.mayLoad(URL(string: allowed)!), allowed)
        }
        for refused in ["file:///tmp/x", "search://settings", "mailto:a@b.c", "tel:1", "zoommtg://x", "x-apple.systempreferences:x"] {
            XCTAssertFalse(AgentRules.mayLoad(URL(string: refused)!), refused)
        }
    }

    // MARK: - tabs

    func testPrivateTabsAreNeverThere() {
        var consent = AgentConsent()
        consent.hello()
        consent.answer(allow: true, seesTabs: true)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let shy = Tab(shy: true, configuration: configuration)
        let yours = Tab(configuration: configuration)
        XCTAssertEqual(AgentRules.refusal(for: shy, own: false, consent: consent, use: .read), "stale_page")
        XCTAssertEqual(AgentRules.refusal(for: shy, own: true, consent: consent, use: .read), "stale_page")
        XCTAssertNil(AgentRules.refusal(for: yours, own: false, consent: consent, use: .read))
        XCTAssertEqual(AgentRules.refusal(for: yours, own: false, consent: consent, use: .drive), "not_yours")
    }

    // MARK: - keys, conditions, names, pace

    func testKeysNeverCommands() {
        XCTAssertEqual(AgentRules.key("Enter")?.code, 36)
        XCTAssertEqual(AgentRules.key("shift+Tab")?.flags.contains(.shift), true)
        XCTAssertEqual(AgentRules.key("a")?.characters, "a")
        XCTAssertEqual(AgentRules.key("shift++")?.characters, "+")
        XCTAssertEqual(AgentRules.key("ctrl+ArrowLeft")?.flags.contains(.control), true)
        // H2: Cocoa's Emacs keys cut and yank: ctrl and a character, never.
        for refused in ["cmd+v", "cmd+a", "command+w", "meta+c", "shift+cmd+n", "", "ab", "hyper+x",
                        "ctrl+k", "ctrl+y", "control+k", "ctrl+shift+y", "ctrl+a", "ctrl+t", "ctrl+1", "ctrl++"] {
            XCTAssertNil(AgentRules.key(refused), refused)
        }
    }

    // H1: no CSS of the agent's, escaped or not; on your tabs, only the
    // address and title, matched against the address with its secrets out.
    func testNoSelectorsAtAll() {
        for selector in ["input[value^='a']", #"[va\lue^="a"]"#, #"[v\61lue^="a"]"#, "input:placeholder-shown",
                         "input:invalid", "input:autofill", "#done"] {
            guard case .failure(let refusal) = AgentRules.condition(["selector": selector], own: true) else {
                return XCTFail("took \(selector)")
            }
            XCTAssertEqual(refusal.code, "bad_condition")
        }
        guard case .success(let own) = AgentRules.condition(["text": "Hello", "role": "button", "name": "Send"], own: true)
        else { return XCTFail("text, role and name, on its own tab") }
        XCTAssertEqual(own.page.count, 3)
        for key in ["text", "role", "name"] {
            guard case .failure = AgentRules.condition([key: "x"], own: false) else { return XCTFail("\(key) on your tab") }
        }
        guard case .success(let yours) = AgentRules.condition(["url": "/done", "title": "done"], own: false)
        else { return XCTFail("url and title on your tab") }
        XCTAssertTrue(yours.page.isEmpty)
        XCTAssertTrue(yours.met(page: true, url: "https://a.test/done?pw=hunter2", title: "done"))
        // The address's secret is never something to wait on.
        guard case .success(let probing) = AgentRules.condition(["url": "pw=h"], own: false) else { return XCTFail() }
        XCTAssertFalse(probing.met(page: true, url: "https://a.test/done?pw=hunter2", title: ""))
        guard case .success(let gone) = AgentRules.condition(["title": "Loading", "gone": true], own: false) else { return XCTFail() }
        XCTAssertTrue(gone.met(page: true, url: "", title: "Done"))
    }

    // L3
    func testSecretsTakenOutOfAddresses() {
        XCTAssertEqual(AgentRules.url("https://a.test/done?name=Ada&pw=hunter2"), "https://a.test/done?name=Ada&pw=redacted")
        XCTAssertEqual(AgentRules.url("https://a.test/?password=x&otp=123456&code=9&token=t&q=cats"),
                       "https://a.test/?password=redacted&otp=redacted&code=redacted&token=redacted&q=cats")
        XCTAssertEqual(AgentRules.url("https://a.test/cb#access_token=abc&state=1"), "https://a.test/cb#access_token=redacted&state=1")
        XCTAssertEqual(AgentRules.url("https://a.test/?q=pass"), "https://a.test/?q=pass", "a value is only hidden by its name")
        XCTAssertEqual(AgentRules.url("https://a.test/#top"), "https://a.test/#top")
        XCTAssertEqual(AgentRules.url(""), "")
        for name in ["mdp", "kennwort", "pw1", "pwd2", "contrasena", "senha", "haslo", "passwd"] {
            XCTAssertEqual(AgentRules.url("https://a.test/?\(name)=s3cret"), "https://a.test/?\(name)=redacted", name)
        }
        XCTAssertEqual(AgentRules.scrubbed("Couldn't open https://a.test/x?token=abc: refused. Also http://b.test/?q=1"),
                       "Couldn't open https://a.test/x?token=redacted: refused. Also http://b.test/?q=1")
    }

    // M4: a fresh mouse click, on the control pressed, in its window.
    func testOnlyAFreshClickOnTheControlAnswers() throws {
        _ = NSApplication.shared
        func window() -> NSWindow {
            NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 200), styleMask: [.titled],
                     backing: .buffered, defer: false)
        }
        let here = window(), other = window()
        let button = NSView(frame: NSRect(x: 100, y: 50, width: 80, height: 30))
        here.contentView?.addSubview(button)
        let asked: TimeInterval = 1000
        func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, at time: TimeInterval) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let middle = button.convert(NSPoint(x: 40, y: 15), to: nil)
        func click(_ event: NSEvent?) -> Bool { AgentRules.isClick(event, on: button, in: here, after: asked + 0.5) }
        XCTAssertFalse(click(nil), "Accessibility's press has no event")
        XCTAssertTrue(click(mouse(.leftMouseUp, at: middle, in: here, at: asked + 1)))
        XCTAssertTrue(click(mouse(.leftMouseDown, at: middle, in: here, at: asked + 1)))
        XCTAssertFalse(click(mouse(.leftMouseUp, at: middle, in: here, at: asked - 3)), "an earlier click still current")
        XCTAssertFalse(click(mouse(.leftMouseUp, at: middle, in: here, at: asked + 0.3)), "in the question's first half second")
        XCTAssertFalse(click(mouse(.leftMouseUp, at: NSPoint(x: 10, y: 10), in: here, at: asked + 1)), "beside the button")
        XCTAssertFalse(click(mouse(.leftMouseUp, at: middle, in: other, at: asked + 1)), "in another window")
        XCTAssertFalse(click(mouse(.rightMouseUp, at: middle, in: here, at: asked + 1)))
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: asked + 1, windowNumber: here.windowNumber,
                                   context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        XCTAssertFalse(click(key), "Return never allows")
        XCTAssertFalse(AgentRules.isClick(mouse(.leftMouseUp, at: middle, in: here, at: asked + 1), on: nil, in: here, after: asked))
    }

    // Low 3: no control characters but tab and newline.
    func testNoControlCharacters() {
        XCTAssertTrue(AgentRules.typeable("Ada\tLovelace\nline two"))
        XCTAssertFalse(AgentRules.typeable("\u{0b}"))
        XCTAssertFalse(AgentRules.typeable("x\u{19}"))
        XCTAssertFalse(AgentRules.typeable("\u{1b}"))
        XCTAssertNil(AgentRules.key("\u{0b}"))
        XCTAssertNil(AgentRules.key("shift+\u{19}"))
    }

    func testClientNames() {
        XCTAssertEqual(AgentRules.clientName("Claude Code"), "Claude Code")
        XCTAssertEqual(AgentRules.clientName("“Search” wants\nto"), "Search wantsto")
        XCTAssertEqual(AgentRules.clientName(""), "A program")
        XCTAssertEqual(AgentRules.clientName(nil), "A program")
        XCTAssertEqual(AgentRules.clientName(String(repeating: "x", count: 200)).count, 40)
    }

    func testPace() {
        var pace = AgentPace()
        for n in 0..<8 { XCTAssertEqual(pace.delay(at: 100), 0, "burst \(n)") }
        XCTAssertEqual(pace.delay(at: 100), 0.2, accuracy: 0.001)
        // Run as told: a second later, five more are free.
        var later = AgentPace()
        for _ in 0..<9 { _ = later.delay(at: 0) }
        XCTAssertEqual(later.delay(at: 1.2), 0, accuracy: 0.001)
    }

    // MARK: - no password filling, by any agent

    /// sign_in is gone: AgentControl refuses it as a verb it doesn't do,
    /// before anything is looked at, and no verb it does fills a login.
    func testSignInIsNotAVerb() {
        XCTAssertFalse(AgentControl.verbs.contains("sign_in"))
        XCTAssertEqual(AgentControl.unknown("sign_in")?.code, "no_verb")
        XCTAssertEqual(AgentControl.unknown("signIn")?.code, "no_verb")
        XCTAssertEqual(AgentControl.unknown("fill")?.code, "no_verb")
        for verb in ["hello", "open", "read", "click", "type", "press", "bye"] { XCTAssertNil(AgentControl.unknown(verb), verb) }
    }

    /// cairn-mcp, as an agent sees it: no sign_in in its tools, a call to
    /// one answered as no such tool, and its words say signing in is the
    /// person's. Run as an agent runs it, with nothing connected to Search.
    func testTheMCPServerOffersNoSignIn() throws {
        // Built beside the tests (Package.swift names it as theirs).
        let built = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("cairn-mcp")
        let run = Process()
        run.executableURL = built
        run.arguments = ["--world", "agent-tests-no-socket"]
        let input = Pipe(), output = Pipe()
        run.standardInput = input
        run.standardOutput = output
        run.standardError = FileHandle.nullDevice
        try run.run()
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sign_in","arguments":{"page":"p1"}}}"#,
        ]
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        run.waitUntilExit()
        let answers = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(answers.count, 3)
        let instructions = try XCTUnwrap((answers[0]["result"] as? [String: Any])?["instructions"] as? String)
        XCTAssertTrue(instructions.contains("never fills a saved password"))
        XCTAssertTrue(instructions.contains("sign in themselves"))
        let tools = try XCTUnwrap((answers[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("open_tab"))
        XCTAssertFalse(names.contains("sign_in"))
        XCTAssertFalse(tools.contains { ($0["description"] as? String ?? "").contains("saved login") })
        let call = try XCTUnwrap(answers[2]["result"] as? [String: Any])
        XCTAssertEqual(call["isError"] as? Bool, true)
        XCTAssertTrue(String(describing: call["content"] ?? "").contains("no_tool"))
    }

    // MARK: - the panel's own run

    private func started(_ seconds: Int, _ micro: Int32 = 0) -> timeval { timeval(tv_sec: seconds, tv_usec: micro) }

    /// The panel's own run is let in by its Send, and nothing else is: a
    /// connection without the run's pass, with a pass but from any process
    /// but a child of the panel's own `claude`, from a pid reused since, or
    /// with no message of the person's being answered, is asked about (the
    /// question, Allow) as every other agent is.
    func testOnlyThePanelsOwnRunIsLetInWithoutAsking() {
        let pass = PanelRun.newPass()
        XCTAssertEqual(pass.count, 64)
        XCTAssertNotEqual(pass, PanelRun.newPass())
        var run = PanelRun(pass: pass, pid: 4242, started: started(100, 5))
        // Not armed: no message of the person's is being answered.
        XCTAssertFalse(run.admits(offered: pass, parent: 4242, parentStarted: started(100, 5)))
        run.armed = true
        XCTAssertTrue(run.admits(offered: pass, parent: 4242, parentStarted: started(100, 5)), "the run, while a Send is answered")
        // Without the pass: asked.
        XCTAssertFalse(run.admits(offered: nil, parent: 4242, parentStarted: started(100, 5)))
        XCTAssertFalse(run.admits(offered: "", parent: 4242, parentStarted: started(100, 5)))
        XCTAssertFalse(run.admits(offered: String(pass.dropLast()) + "0", parent: 4242, parentStarted: started(100, 5)))
        XCTAssertFalse(run.admits(offered: pass.uppercased(), parent: 4242, parentStarted: started(100, 5)))
        // With the pass, from anyone but the panel's own claude: asked.
        XCTAssertFalse(run.admits(offered: pass, parent: 4243, parentStarted: started(100, 5)), "another program that read it")
        XCTAssertFalse(run.admits(offered: pass, parent: nil, parentStarted: nil))
        XCTAssertFalse(run.admits(offered: pass, parent: 1, parentStarted: started(100, 5)), "an orphan, adopted by launchd")
        XCTAssertFalse(run.admits(offered: pass, parent: 4242, parentStarted: started(101, 5)), "the pid given to someone else since")
        XCTAssertFalse(run.admits(offered: pass, parent: 4242, parentStarted: started(100, 6)))
        XCTAssertFalse(run.admits(offered: pass, parent: 4242, parentStarted: nil))
        // A run whose start couldn't be read lets nobody in.
        var unknown = PanelRun(pass: pass, pid: 4242, started: nil)
        unknown.armed = true
        XCTAssertFalse(unknown.admits(offered: pass, parent: 4242, parentStarted: started(100, 5)))
        // No randomness, no pass: nothing matches an empty one.
        var empty = PanelRun(pass: "", pid: 4242, started: started(100, 5))
        empty.armed = true
        XCTAssertFalse(empty.admits(offered: "", parent: 4242, parentStarted: started(100, 5)))
    }

    /// The same through AgentControl: a pass registered for a run, armed by
    /// Send, does nothing for a pass nobody registered, and nothing once the
    /// turn is over or the run is gone.
    func testThePanelsPassIsArmedBySendAndGoesWithTheRun() {
        let control = AgentControl.shared
        let pass = PanelRun.newPass()
        control.panelStarted(pass: pass, pid: getpid(), browser: nil)
        defer { control.panelEnded(pass: pass) }
        let me = AgentIdentity.process(getpid())?.started
        XCTAssertFalse(control.panelAdmitsForTest(offered: pass, parent: getpid(), parentStarted: me), "not before Send")
        control.panelArm(pass: pass, true)
        XCTAssertTrue(control.panelAdmitsForTest(offered: pass, parent: getpid(), parentStarted: me))
        XCTAssertFalse(control.panelAdmitsForTest(offered: PanelRun.newPass(), parent: getpid(), parentStarted: me), "a pass of no run")
        XCTAssertFalse(control.panelAdmitsForTest(offered: nil, parent: getpid(), parentStarted: me), "no pass: the question")
        control.panelArm(pass: pass, false)
        XCTAssertFalse(control.panelAdmitsForTest(offered: pass, parent: getpid(), parentStarted: me), "the turn over")
        control.panelArm(pass: pass, true)
        control.panelEnded(pass: pass)
        XCTAssertFalse(control.panelAdmitsForTest(offered: pass, parent: getpid(), parentStarted: me), "the run gone")
    }

    // MARK: - what a page gives back

    private func page(_ html: String) async throws -> WKWebView {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: {
            let c = WKWebViewConfiguration()
            c.websiteDataStore = .nonPersistent()
            return c
        }())
        PageRoom.shared.made().contentView?.addSubview(web)
        web.loadHTMLString(html, baseURL: URL(string: "https://agent-test.invalid/"))
        for _ in 0..<100 where web.isLoading || web.url == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        return web
    }

    private func run(_ web: WKWebView, _ script: String) async throws -> [String: Any] {
        let value = try await web.evaluateJavaScript(script, contentWorld: Web.world)
        let text = try XCTUnwrap(value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: - how a task ends

    /// A task that finished leaves its tabs to the person; their Stop, a No
    /// to another site, quitting, a window going or a program that misbehaved
    /// closes them.
    func testAFinishedTaskHandsOverItsTabsAndStopClosesThem() {
        for how: AgentEnd in [.bye, .connectionClosed, .idle] {
            XCTAssertTrue(how.handsOver(declined: false), how.why)
            XCTAssertFalse(how.handsOver(declined: true), "\(how.why), after the person said no to a site change")
        }
        for how: AgentEnd in [.stopped, .appStopped, .windowClosed, .noWindow, .silent, .tooMuch, .notReading, .notAllowed] {
            XCTAssertFalse(how.handsOver(declined: false), how.why)
            XCTAssertFalse(how.handsOver(declined: true), how.why)
        }
        // Stop's own words still begin as before, for the log.
        XCTAssertTrue(AgentEnd.stopped.why.hasPrefix("stopped"))
    }

    /// The tab it last worked in comes forward only for the panel's run, in
    /// a window you are in, with nobody typing or in the address field.
    func testTheResultIsBroughtForwardOnlyWhenNobodyIsTyping() {
        XCTAssertTrue(AgentEnd.landsOnResult(panel: true, windowActive: true, editingAddress: false, sinceKey: 10))
        XCTAssertFalse(AgentEnd.landsOnResult(panel: false, windowActive: true, editingAddress: false, sinceKey: 10), "a program in a terminal")
        XCTAssertFalse(AgentEnd.landsOnResult(panel: true, windowActive: false, editingAddress: false, sinceKey: 10), "you are elsewhere")
        XCTAssertFalse(AgentEnd.landsOnResult(panel: true, windowActive: true, editingAddress: true, sinceKey: 10), "typing an address")
        XCTAssertFalse(AgentEnd.landsOnResult(panel: true, windowActive: true, editingAddress: false, sinceKey: 0.5), "typing into a page")
    }

    /// The panel's Stop is the person's Stop only for the run it is: another
    /// pass, or no session at all, ends nothing.
    func testThePanelsStopIsOnlyForItsOwnRun() {
        let control = AgentControl.shared
        XCTAssertNil(control.session)
        control.panelStopped(pass: PanelRun.newPass())
        XCTAssertNil(control.session)
        XCTAssertEqual(control.state["connected"] as? Bool, false)
    }

    /// The model is told its tabs stay for the person, to name the tab by its
    /// title and not guess where it is, and to leave a video playing.
    func testTheModelIsToldItsTabsStay() throws {
        let brief = ClaudeCode.brief()
        XCTAssertTrue(brief.contains("call disconnect"))
        XCTAssertTrue(brief.contains("stay open as the person's"))
        XCTAssertTrue(brief.contains("by its title"))
        XCTAssertTrue(brief.contains("never say it is behind"))
        XCTAssertTrue(brief.contains("leave it playing"))
        let text = MCPTools.instructions
        XCTAssertTrue(text.contains("your tabs then stay"))
        XCTAssertTrue(text.contains("don't say it is behind"))
        XCTAssertTrue(text.contains("leave it"))
        XCTAssertFalse(text.contains("new tab of your own, behind the person's"), "the tab may well be in front by the end")
    }

    func testSecretValuesNeverLeaveThePage() async throws {
        let web = try await page("""
            <!doctype html><title>secrets</title>
            <label>Name <input id=name value="Ada"></label>
            <label>Password <input type=password id=pw value="hunter2"></label>
            <label>Card <input id=cc autocomplete="cc-number" value="4242424242424242"></label>
            <label>Security code <input id=cvc value="123"></label>
            <label>Code <input id=otp autocomplete="one-time-code" value="987654"></label>
            <label>Shown <input type=password id=shown value="opensesame"></label>
            <button id=show onclick="document.getElementById('shown').type='text'">Show</button>
            """)
        defer { web.removeFromSuperview() }
        let first = try await run(web, PageScripts.read(key: "__test", snap: 1, most: 50, longest: 5000, text: true))
        // The field shown as text after it was read as a password.
        _ = try await web.evaluateJavaScript("document.getElementById('shown').type = 'text'; true")
        let second = try await run(web, PageScripts.read(key: "__test", snap: 2, most: 50, longest: 5000, text: true))
        for out in [first, second] {
            let all = String(data: try JSONSerialization.data(withJSONObject: out), encoding: .utf8) ?? ""
            for secret in ["hunter2", "4242424242424242", "987654", "opensesame"] {
                XCTAssertFalse(all.contains(secret), "\(secret) left the page")
            }
            XCTAssertFalse(all.contains("\"value\":\"123\""), "the card's code left the page")
            XCTAssertTrue(all.contains("Ada"), "an ordinary field's value is read")
            let nodes = out["nodes"] as? [[String: Any]] ?? []
            XCTAssertEqual(nodes.filter { $0["redacted"] as? Bool == true }.count, 5)
        }
        // Typing into a secret field says whether it took, never what it held.
        let index = (second["nodes"] as? [[String: Any]] ?? []).firstIndex { $0["name"] as? String == "Password" } ?? -1
        let focused = try await run(web, PageScripts.touch(key: "__test", snap: 2, index: index, how: "focus", text: "x", replace: false))
        XCTAssertTrue(focused["want"] is NSNull || focused["want"] == nil, "what it held stays in the page")
        let wrong = try await run(web, PageScripts.touch(key: "__test", snap: 2, index: index, how: "verify", text: "guess", replace: true))
        XCTAssertEqual(wrong["verified"] as? Bool, false)
        XCTAssertNil(wrong["holds"])
        // And where a picture must be blacked out: the five fields.
        let boxes = try await run(web, PageScripts.secrets)
        XCTAssertEqual((boxes["boxes"] as? [[Double]])?.count, 5)
    }

    func testFileFieldsAreLeftToYou() async throws {
        let web = try await page("<!doctype html><input type=file id=f><button>Go</button>")
        defer { web.removeFromSuperview() }
        let read = try await run(web, PageScripts.read(key: "__test", snap: 1, most: 50, longest: 100, text: false))
        let index = (read["nodes"] as? [[String: Any]] ?? []).firstIndex { $0["role"] as? String == "button" && $0["name"] as? String != "Go" } ?? 0
        let touched = try await run(web, PageScripts.touch(key: "__test", snap: 1, index: index, how: "click", text: nil, replace: true, strict: true))
        XCTAssertEqual(touched["error"] as? String, "file_input")
    }

    // MARK: - the socket

    func testSocketIsThisUsersOnly() throws {
        let control = AgentControl.shared
        // Listening already, as every first window now starts it: from scratch.
        control.stop()
        let path = AgentControl.socket.path, dir = AgentControl.folder.path
        try FileManager.default.createDirectory(at: AgentControl.folder, withIntermediateDirectories: true)
        // A folder left open to everyone, and a file there before, are not kept as they were.
        chmod(dir, 0o777)
        FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o666])
        let mask = umask(0o022)
        umask(mask)
        control.start()
        defer {
            control.stop()
            try? FileManager.default.removeItem(at: AgentControl.folder)
        }
        XCTAssertTrue(control.running)
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertEqual(lstat(dir, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(info.st_mode & 0o777, 0o700, "the folder only this user can open")
        XCTAssertTrue(path.hasPrefix(Store.folder.path), "in Search's own folder")
        let now = umask(0o022)
        umask(now)
        XCTAssertEqual(now, mask, "the process's umask is left alone")
        control.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "gone when turned off")
    }

    // L4: a folder that is a link to somewhere else is not listened in.
    func testALinkedFolderIsRefused() throws {
        // Listening already, as every first window now starts it: from scratch.
        AgentControl.shared.stop()
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("agent-elsewhere-\(getpid())")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: AgentControl.folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: AgentControl.folder)
        try FileManager.default.createSymbolicLink(at: AgentControl.folder, withDestinationURL: elsewhere)
        defer {
            AgentControl.shared.stop()
            try? FileManager.default.removeItem(at: AgentControl.folder)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        XCTAssertNil(AgentControl.listen())
        AgentControl.shared.start()
        XCTAssertFalse(AgentControl.shared.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("agent.sock").path))
    }

    // M3: what Search fills, and any box once a password, stay secret.
    func testWhatSearchFillsStaysSecret() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(source: FormRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        PageRoom.shared.made().contentView?.addSubview(web)
        defer { web.removeFromSuperview() }
        web.loadHTMLString("""
            <!doctype html><title>fill</title>
            <form><label>Email <input id=user type=email></label>
            <label>Secret <input id=pass type=password></label></form>
            <div id=cells><input id=c0 maxlength=1 autocomplete=one-time-code inputmode=numeric><input id=c1 maxlength=1 inputmode=numeric>
            <input id=c2 maxlength=1 inputmode=numeric><input id=c3 maxlength=1 inputmode=numeric></div>
            <label>Later <input id=later type=password></label>
            """, baseURL: URL(string: "https://agent-fill.invalid/"))
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let filled = try await web.evaluateJavaScript("""
            var ok = window.__officeForms.fill('ada@example.test', 'filled-pw-1');
            document.getElementById('c0').focus();
            var coded = window.__officeForms.code('4831');
            // A password box focused and typed in, never read before it is shown as text.
            var later = document.getElementById('later'); later.focus(); later.value = 'typed-pw-2';
            later.dispatchEvent(new Event('input', { bubbles: true }));
            // Every box shown as plain text, as "show password" would.
            ['pass', 'later'].forEach(function (id) { document.getElementById(id).type = 'text'; });
            ['c0', 'c1', 'c2', 'c3'].forEach(function (id) { document.getElementById(id).removeAttribute('autocomplete'); });
            JSON.stringify([ok, coded, document.getElementById('c1').value]);
            """, contentWorld: Web.world) as? String
        XCTAssertEqual(filled, #"[true,true,"8"]"#, "Search filled the password and the code")
        let read = try await run(web, PageScripts.read(key: "__test", snap: 1, most: 50, longest: 5000, text: true))
        let all = String(data: try JSONSerialization.data(withJSONObject: read), encoding: .utf8) ?? ""
        for secret in ["filled-pw-1", "typed-pw-2", "\"value\":\"4\"", "\"value\":\"8\"", "\"value\":\"3\"", "\"value\":\"1\""] {
            XCTAssertFalse(all.contains(secret), "\(secret) left the page")
        }
        XCTAssertTrue(all.contains("ada@example.test"), "the name Search filled is not a secret")
        let boxes = try await run(web, PageScripts.secrets)
        XCTAssertEqual((boxes["boxes"] as? [[Double]])?.count, 6, "the password, the four cells and the later one")
    }

    // M2: whatever can't be read is blacked out of a picture.
    func testPicturesBlackOutWhatCantBeRead() async throws {
        let web = try await page("""
            <!doctype html><title>frames</title>
            <iframe srcdoc="<p>same origin</p>" style="width:200px;height:100px"></iframe>
            <iframe src="https://elsewhere.invalid/" style="width:200px;height:100px"></iframe>
            <embed type="text/plain" style="width:100px;height:50px">
            <closed-thing style="display:block;width:120px;height:40px"></closed-thing>
            <script>customElements.define('closed-thing', class extends HTMLElement {
              constructor() { super(); this.attachShadow({ mode: 'closed' }).innerHTML = '<input value="4242">'; } });</script>
            <open-thing style="display:block;width:120px;height:40px"></open-thing>
            <script>customElements.define('open-thing', class extends HTMLElement {
              constructor() { super(); this.attachShadow({ mode: 'open' }).innerHTML = '<input type=password value="x">'; } });</script>
            <p>Plain <input value="shown"></p>
            """)
        defer { web.removeFromSuperview() }
        let boxes = try await run(web, PageScripts.secrets)
        // Two frames, the embed, the closed root's host, the open root's password.
        XCTAssertEqual((boxes["boxes"] as? [[Double]])?.count, 5, "\(boxes)")
    }

    // Low 9: a closed root on a standard element, up to a widget's size.
    func testClosedRootsOnStandardElements() async throws {
        let web = try await page("""
            <!doctype html><div id=small style="width:200px;height:40px"></div>
            <div id=wide style="width:1200px;height:600px"></div>
            <script>document.getElementById('small').attachShadow({ mode: 'closed' }).innerHTML = '<b>4242</b>';</script>
            """)
        defer { web.removeFromSuperview() }
        let boxes = try await run(web, PageScripts.secrets)
        XCTAssertEqual((boxes["boxes"] as? [[Double]])?.count, 1, "the small one, not a page-sized background")
    }

    // M2a: hidden in the page for the picture, then put back as it was.
    func testHiddenForThePictureAndPutBack() async throws {
        let web = try await page("""
            <!doctype html><input id=pw type=password value=x>
            <iframe id=f srcdoc="hi" style="opacity:0.5"></iframe><input id=plain value=y>
            """)
        defer { web.removeFromSuperview() }
        func opacity(_ id: String) async throws -> String {
            try await web.evaluateJavaScript("getComputedStyle(document.getElementById('\(id)')).opacity") as? String ?? ""
        }
        let hidden = try await run(web, PageScripts.hidden(key: "__testHidden"))
        XCTAssertEqual((hidden["boxes"] as? [[Double]])?.count, 2)
        let duringPw = try await opacity("pw"), duringFrame = try await opacity("f"), duringPlain = try await opacity("plain")
        XCTAssertEqual(duringPw, "0")
        XCTAssertEqual(duringFrame, "0")
        XCTAssertEqual(duringPlain, "1")
        let shown = try await run(web, PageScripts.shown(key: "__testHidden"))
        XCTAssertEqual(shown["shown"] as? Int, 2)
        let afterPw = try await opacity("pw"), afterFrame = try await opacity("f")
        XCTAssertEqual(afterPw, "1")
        XCTAssertEqual(afterFrame, "0.5", "its own opacity put back")
    }

    // Low 4: in a shadow root, swapped for a text box, or typed into a code row.
    func testSecretsSearchSeesOnItsOwn() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(source: FormRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        PageRoom.shared.made().contentView?.addSubview(web)
        defer { web.removeFromSuperview() }
        web.loadHTMLString("""
            <!doctype html><title>own</title>
            <login-box id=host></login-box>
            <script>document.getElementById('host').attachShadow({ mode: 'open' }).innerHTML =
              '<label>Key <input id=inner type=password></label>';</script>
            <span id=swap><input id=pw type=password></span>
            <div id=row><input maxlength=1><input maxlength=1><input maxlength=1><input maxlength=1></div>
            """, baseURL: URL(string: "https://agent-own.invalid/"))
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await web.evaluateJavaScript("""
            var inner = document.getElementById('host').shadowRoot.getElementById('inner');
            inner.focus(); inner.value = 'shadow-pw-3'; inner.type = 'text';
            var pw = document.getElementById('pw'); pw.focus(); pw.value = 'swapped-pw-4';
            var shown = document.createElement('input'); shown.value = pw.value;
            pw.replaceWith(shown);
            document.querySelectorAll('#row input').forEach(function (b, i) {
              b.value = String(7 - i); b.dispatchEvent(new Event('input', { bubbles: true }));
            });
            true
            """)
        try await Task.sleep(nanoseconds: 200_000_000)
        let read = try await run(web, PageScripts.read(key: "__test", snap: 1, most: 50, longest: 5000, text: true))
        let all = String(data: try JSONSerialization.data(withJSONObject: read), encoding: .utf8) ?? ""
        for secret in ["shadow-pw-3", "swapped-pw-4", "\"value\":\"7\"", "\"value\":\"6\"", "\"value\":\"5\"", "\"value\":\"4\""] {
            XCTAssertFalse(all.contains(secret), "\(secret) left the page")
        }
    }

    // H2, tried for real: ctrl+k in a password box, ctrl+y in a text box.
    // Refused in `press` either way; this records what WebKit itself does.
    func testWhatEmacsKeysDoToAPassword() async throws {
        let web = try await page("<!doctype html><input id=pw type=password value=hunter2><input id=out>")
        defer { web.removeFromSuperview() }
        _ = try await web.evaluateJavaScript("var p = document.getElementById('pw'); p.focus(); p.setSelectionRange(0, 0); true")
        PageRoom.shared.made().makeFirstResponder(web)
        PageHands.key(web, code: 40, characters: "\u{0b}", flags: .control)
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await web.evaluateJavaScript("document.getElementById('out').focus(); true")
        PageHands.key(web, code: 16, characters: "\u{19}", flags: .control)
        try await Task.sleep(nanoseconds: 300_000_000)
        let out = try await web.evaluateJavaScript("document.getElementById('out').value") as? String ?? ""
        let pw = try await web.evaluateJavaScript("document.getElementById('pw').value") as? String ?? ""
        print("AgentControlTests: ctrl+k in a password box left it \(pw.isEmpty ? "empty" : "as it was"); ctrl+y yanked “\(out.isEmpty ? "" : out == "hunter2" ? "the password" : "something else")”")
        XCTAssertNil(AgentRules.key("ctrl+k"))
        XCTAssertNil(AgentRules.key("ctrl+y"))
    }

}
