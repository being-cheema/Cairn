import CairnProtocol
import WebKit
import XCTest
@testable import Search

/// Signing in is the person's: what an agent's tab is kept from, and what
/// stays hidden after the person has had it.
@MainActor
final class PassTheBatonTests: XCTestCase {
    func testAnAgentsTabIsKeptFromYoursUnlessItIsInYourHands() {
        let yours = Tab()
        XCTAssertFalse(yours.keptFromYou)
        let tab = Tab(bench: true)
        tab.agent = true
        XCTAssertTrue(tab.keptFromYou)
        tab.inYourHands = true
        XCTAssertFalse(tab.keptFromYou)
    }

    func testTheCardSaysWhatResumeGives() {
        XCTAssertEqual(AgentBatonCard.title(client: "Claude", own: true), "Claude is paused for you to sign in")
        XCTAssertEqual(AgentBatonCard.title(client: "Claude", own: false), "“Claude” is paused for you to sign in")
        let hold = AgentGate.Hold(reason: .signIn, summary: "Sign in on a.com", site: "a.com")
        XCTAssertTrue(AgentBatonCard.detail(hold).contains("a.com"))
        XCTAssertTrue(AgentBatonCard.footnote.contains("use this account"))
        XCTAssertTrue(PanelWaiting.say(hold).contains("a.com"))
    }

    func testThereIsAToolToHandTheSignInOverAndNoneToDoIt() throws {
        let tool = try XCTUnwrap(MCPTools.all.first { $0.name == "wait_for_sign_in" })
        XCTAssertEqual(tool.verb, .waitForSignIn)
        XCTAssertEqual(tool.passes, ["page"], "nothing but which page: no name, no password")
        XCTAssertNil(MCPTools.all.first { $0.name == "sign_in" })
    }

    /// A code box that doesn't say it is one: hidden once sealed, and for
    /// good, shown as text or not.
    func testWhatWasTypedStaysHiddenAfterTheSeal() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let loaded = Loaded()
        web.navigationDelegate = loaded
        web.loadHTMLString("""
            <label>Reply <input id=a value="482913"></label>
            <label>Empty <input id=b></label>
            <textarea aria-label="Words">recovery words here</textarea>
            <input type=password id=p>
            <input type=checkbox checked>
            <div id=host></div>
            <script>document.getElementById('host').attachShadow({mode:'open'}).innerHTML = '<input aria-label="Inside" value="shadow-secret">'</script>
            """, baseURL: URL(string: "https://example.com/"))
        await loaded.wait()
        func run(_ script: String) async throws -> String {
            let out = try await web.evaluateJavaScript(script, in: nil, contentWorld: Web.world)
            return out as? String ?? ""
        }
        let before = try await run(PageScripts.read(key: "__t", snap: 1, most: 50, longest: 0, text: false))
        XCTAssertTrue(before.contains("482913"), "an ordinary box is read until it is sealed")
        let sealed = try await run(PageScripts.seal())
        XCTAssertTrue(sealed.contains("\"sealed\":4"), sealed)
        _ = try await web.evaluateJavaScript("document.getElementById('p').type = 'text'; true")
        let after = try await run(PageScripts.read(key: "__t", snap: 2, most: 50, longest: 0, text: false))
        for secret in ["482913", "recovery words here", "shadow-secret"] {
            XCTAssertFalse(after.contains(secret), "\(secret) was read after the seal")
        }
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        private var done = false
        private var waiting: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done = true
            waiting?.resume()
            waiting = nil
        }
        func wait() async {
            if done { return }
            await withCheckedContinuation { waiting = $0 }
        }
    }
}
