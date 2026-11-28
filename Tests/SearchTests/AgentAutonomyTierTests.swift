import XCTest
@testable import Search

/// Standard, Trusted Hub and Vaulted, one per site, set only from the site
/// card. A hub removes one question and no other.
@MainActor
final class AgentAutonomyTierTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private let registrable: (String) -> String = { host in host.split(separator: ".").suffix(2).joined(separator: ".") }
    private func url(_ text: String) -> URL { URL(string: text)! }

    func testTheTierIsOneOfThreeAndVaultedOutranksAHub() {
        let page = url("https://docs.hub.example/a")
        XCTAssertEqual(AutonomyTiers.tier(of: page, vaulted: [], hubs: []), .standard)
        XCTAssertEqual(AutonomyTiers.tier(of: page, vaulted: [], hubs: ["hub.example"]), .trustedHub)
        XCTAssertEqual(AutonomyTiers.tier(of: page, vaulted: ["hub.example"], hubs: ["hub.example"]), .vaulted)
        XCTAssertEqual(AutonomyTiers.tier(of: url("https://nothub.example/"), vaulted: [], hubs: ["hub.example"]), .standard, "a label's edge")
    }

    func testChoosingATierMovesTheSiteBetweenTheTwoListsAndClearsTheOther() {
        let page = url("https://www.hub.example/")
        var lists = AutonomyTiers.setting(.trustedHub, for: page, vaulted: ["hub.example"], hubs: [], registrable: registrable)
        XCTAssertEqual(lists.hubs, ["hub.example"])
        XCTAssertTrue(lists.vaulted.isEmpty, "no longer blocked")
        lists = AutonomyTiers.setting(.vaulted, for: page, vaulted: lists.vaulted, hubs: lists.hubs, registrable: registrable)
        XCTAssertEqual(lists.vaulted, ["hub.example"])
        XCTAssertTrue(lists.hubs.isEmpty)
        lists = AutonomyTiers.setting(.standard, for: page, vaulted: lists.vaulted, hubs: ["hub.example"], registrable: registrable)
        XCTAssertTrue(lists.vaulted.isEmpty && lists.hubs.isEmpty)
    }

    private func link(_ href: String, label: String = "Read more") -> AgentGate.Target {
        var target = AgentGate.Target()
        target.role = "link"
        target.label = label
        target.href = href
        return target
    }

    func testAHubOnlyDropsTheQuestionAboutLeavingForALinkOutOfIt() {
        let here = url("https://hub.example/list")
        let sites: Set<String> = ["hub.example"]
        let out = link("https://elsewhere.test/page")
        let ask = AgentGate.hold(click: out, on: here, sites: sites, rules: .standard, registrable: registrable)
        XCTAssertEqual(ask?.reason, .leave, "a standard site asks")
        XCTAssertNil(AgentGate.hold(click: out, on: here, sites: sites, rules: .standard, hubs: ["hub.example"], registrable: registrable))
        // A link out of a site that isn't the hub still asks.
        XCTAssertEqual(AgentGate.hold(click: out, on: url("https://other.example/"), sites: ["other.example"], rules: .standard,
                                      hubs: ["hub.example"], registrable: registrable)?.reason, .leave)
    }

    func testEveryOtherHoldStaysOnAHub() {
        let here = url("https://hub.example/cart")
        let hubs: Set<String> = ["hub.example"]
        func held(_ label: String, submits: Bool = false, card: Bool = false, pw: Bool = false, role: String = "button",
                  href: String = "") -> AgentGate.Reason? {
            var target = AgentGate.Target()
            target.role = role; target.tag = "button"; target.label = label; target.submits = submits
            target.inForm = submits; target.hasCard = card; target.hasPassword = pw; target.href = href; target.method = "post"
            return AgentGate.hold(click: target, on: here, sites: ["hub.example"], rules: .standard, hubs: hubs, registrable: registrable)?.reason
        }
        XCTAssertEqual(held("Pay now", card: true), .pay)
        XCTAssertEqual(held("Buy"), .pay)
        XCTAssertEqual(held("Send message"), .send)
        XCTAssertEqual(held("Log in", submits: true, pw: true), .signIn)
        XCTAssertEqual(held("Go", submits: true), .submit)
        // A link to pay, out of the hub, is still the payment's question.
        XCTAssertEqual(held("Pay your bill", role: "link", href: "https://elsewhere.test/pay"), .pay)
    }

    func testNothingElseChangesAndTheChoiceIsKeptWithTheOtherSiteSettings() {
        XCTAssertEqual(AutonomyTiers.key, "agents.trustedHubs")
        Store.settings.set(["hub.example"], forKey: AutonomyTiers.key)
        defer { Store.settings.removeObject(forKey: AutonomyTiers.key) }
        XCTAssertEqual(AutonomyTiers.current, ["hub.example"])
        XCTAssertEqual(AutonomyTier.allCases.map(\.title), ["Standard", "Trusted Hub", "Vaulted"])
    }
}
