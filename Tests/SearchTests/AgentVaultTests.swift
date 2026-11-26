import XCTest
@testable import Search

/// Sites the person closed to agents: what counts as the same site, and
/// where the refusal comes (before any gate).
@MainActor
final class AgentVaultTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private let sites: Set<String> = ["bank.com"]
    private func url(_ text: String) -> URL? { URL(string: text) }
    private func blocked(_ text: String, _ set: Set<String>? = nil) -> Bool {
        VaultedSites.blocks(url(text), in: set ?? sites)
    }

    func testASiteCoversItsSubdomains() {
        XCTAssertTrue(blocked("https://bank.com/"))
        XCTAssertTrue(blocked("http://login.bank.com/a?b=1"))
        XCTAssertTrue(blocked("https://a.b.c.bank.com:8443/"))
        XCTAssertTrue(blocked("wss://live.bank.com/socket"))
        XCTAssertTrue(blocked("blob:https://bank.com/1f2e"))
    }

    func testLookAlikesAreOtherSites() {
        XCTAssertFalse(blocked("https://notbank.com/"))
        XCTAssertFalse(blocked("https://bank.com.evil.test/"))
        XCTAssertFalse(blocked("https://bank.co/"))
        XCTAssertFalse(blocked("https://evil.test/bank.com"))
        XCTAssertFalse(blocked("https://evil.test/?u=https://bank.com"))
        XCTAssertFalse(blocked("https://bank.com@evil.test/"))
        // A block on a subdomain leaves its parent and siblings open.
        XCTAssertFalse(blocked("https://bank.com/", ["login.bank.com"]))
        XCTAssertFalse(blocked("https://www.bank.com/", ["login.bank.com"]))
    }

    func testTheSameHostSpeltOtherwise() {
        for spelling in ["https://BANK.com/", "https://bank.com./", "https://login.Bank.COM../",
                         "https://ｂａｎｋ.com/", "https://bank%2Ecom/", "https://bank。com/"] {
            XCTAssertTrue(blocked(spelling), spelling)
        }
        XCTAssertTrue(blocked("https://bank.com/", ["Bank.com."]))
    }

    func testAnotherAlphabetAndItsPunycodeAreOne() {
        XCTAssertTrue(blocked("https://bücher.de/", ["xn--bcher-kva.de"]))
        XCTAssertTrue(blocked("https://shop.XN--BCHER-KVA.de/", ["xn--bcher-kva.de"]))
        XCTAssertEqual(VaultedSites.entry(typed: "BÜCHER.de"), "xn--bcher-kva.de")
        // A Cyrillic look-alike is not the Latin name.
        XCTAssertFalse(blocked("https://bаnk.com/"))
    }

    func testAnAddressSpeltOtherwise() {
        XCTAssertTrue(blocked("http://0x7f.1/", ["127.0.0.1"]))
    }

    func testWhatIsNoSite() {
        XCTAssertFalse(blocked("about:blank"))
        XCTAssertFalse(blocked("data:text/html,bank.com"))
        XCTAssertFalse(blocked("file:///bank.com"))
        XCTAssertFalse(VaultedSites.blocks(nil, in: sites))
        XCTAssertFalse(blocked("https://bank.com/", []))
        XCTAssertFalse(blocked("https://bank.com/", [""]), "an empty entry covers nothing")
    }

    func testWhatIsTyped() {
        XCTAssertEqual(VaultedSites.entry(typed: " https://www.Bank.com/login?x=1 "), "bank.com")
        XCTAssertEqual(VaultedSites.entry(typed: "*.bank.com"), "bank.com")
        XCTAssertEqual(VaultedSites.entry(typed: ".bank.com."), "bank.com")
        XCTAssertEqual(VaultedSites.entry(typed: "pay.bank.com"), "pay.bank.com")
        for nothing in ["", "   ", "bank", "my bank.com", "file:///x", "ftp://bank.com"] {
            XCTAssertNil(VaultedSites.entry(typed: nothing), nothing)
        }
    }

    func testTheCardsSwitchBlocksTheWholeSiteAndTakesEveryCoveringEntryBack() throws {
        let reg: (String) -> String = { $0.split(separator: ".").suffix(2).joined(separator: ".") }
        let page = try XCTUnwrap(url("https://secure.login.bank.com/a"))
        let on = VaultedSites.setting(true, for: page, in: [], registrable: reg)
        XCTAssertEqual(on, ["bank.com"])
        let off = VaultedSites.setting(false, for: page, in: ["bank.com", "login.bank.com", "other.org"], registrable: reg)
        XCTAssertEqual(off, ["other.org"])
    }

    func testOpenAndGoAreRefusedAsTyped() {
        for text in ["https://bank.com/", "login.bank.com/pay", "http://BANK.com./"] {
            XCTAssertEqual(NavigationPolicyEngine.destination(text, allowed: [], vaulted: sites),
                           .failure(.blockedByPerson), text)
        }
        XCTAssertNoThrow(try NavigationPolicyEngine.destination("https://notbank.com/", allowed: [], vaulted: sites).get())
    }

    /// The same question every redirect, link and frame's document is asked
    /// (AgentControl.vet), ahead of the form gate.
    func testEveryDocumentIsAskedFirst() throws {
        for text in ["https://bank.com/r", "blob:https://bank.com/1", "http://x.bank.com/"] {
            let address = try XCTUnwrap(url(text))
            XCTAssertEqual(NavigationPolicyEngine.screen(address, allowed: [], vaulted: sites), .blockedByPerson, text)
        }
        let other = try XCTUnwrap(url("https://notbank.com/"))
        XCTAssertEqual(NavigationPolicyEngine.screen(other, allowed: [], vaulted: sites), .lookUp("notbank.com"))
    }

    func testTheListIsReadAsItStands() {
        let was = Store.settings.object(forKey: VaultedSites.key)
        defer { Store.settings.set(was, forKey: VaultedSites.key) }
        let prefs = Preferences()
        prefs.vaultedSites = ["bank.com"]
        XCTAssertEqual(NavigationPolicyEngine.destination("https://bank.com", allowed: []), .failure(.blockedByPerson))
        XCTAssertEqual(Preferences().vaultedSites, ["bank.com"], "kept")
        prefs.vaultedSites = []
        XCTAssertNoThrow(try NavigationPolicyEngine.destination("https://bank.com", allowed: []).get())
    }

    func testAClickOrReturnTowardsABlockedSite() {
        var link = AgentGate.Target()
        link.role = "link"; link.href = "https://pay.bank.com/x"
        XCTAssertNotNil(VaultedSites.reached(by: link, in: sites))
        link.href = "https://notbank.com/x"
        XCTAssertNil(VaultedSites.reached(by: link, in: sites))
        var button = AgentGate.Target()
        button.submits = true; button.action = "https://bank.com/send"
        XCTAssertNotNil(VaultedSites.reached(by: button, in: sites))
        // A field in that form sends nothing by a click, but Return does.
        button.submits = false
        XCTAssertNil(VaultedSites.reached(by: button, in: sites))
        button.enter = true
        XCTAssertNotNil(VaultedSites.reached(by: button, in: sites))
    }

    /// A tab already on a blocked site, as one of yours or one handed over
    /// is, can't be read, listed or attached.
    func testATabOnABlockedSiteIsSeen() throws {
        let was = Store.settings.object(forKey: VaultedSites.key)
        defer { Store.settings.set(was, forKey: VaultedSites.key) }
        Store.settings.removeObject(forKey: VaultedSites.key)
        let tab = Tab()
        tab.setAddressOptimistically(try XCTUnwrap(url("https://login.bank.com/")))
        XCTAssertFalse(AgentControl.isVaulted(tab))
        XCTAssertTrue(Mentions.mayName(tab))
        Store.settings.set(["bank.com"], forKey: VaultedSites.key)
        XCTAssertTrue(AgentControl.isVaulted(tab))
        XCTAssertFalse(Mentions.mayName(tab))
    }

    func testTheRefusalSaysSo() {
        let said = AgentControl.blockedByPerson("bank.com").said["error"] as? [String: Any]
        XCTAssertEqual(said?["code"] as? String, "blocked_by_user_policy")
    }
}
