import WebKit
import XCTest
@testable import Search

/// The table on an approval card: what a held form holds, without its
/// secrets, and noticed when it changes before the click is carried out.
@MainActor
final class AgentReceiptTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private func made(_ fields: [(String, String)]) throws -> FormReceipt {
        try XCTUnwrap(FormReceipt(["rows": fields.map { ["label": $0.0, "name": "", "value": $0.1] }]))
    }

    func testValuesThatLookSecretAreHidden() throws {
        let receipt = try made([("API token", "abc"), ("Coupon code", "SAVE10"), ("Postal code", "AB1 2CD"),
                                ("Code", "493021"), ("Note", "my card is 4242 4242 4242 4242"),
                                ("Note", "sk-abcdefghijklmnopqrstuvwx"), ("Ref", "a8F3kd9Lq2Zp7Xm4Nb6Vc1Hs5Jt0Rw2Y"),
                                ("IBAN", "GB00"), ("Email", "ada@example.org"), ("Comment", "")])
        XCTAssertEqual(receipt.rows.map(\.value), [TypedSecrets.mark, "SAVE10", "AB1 2CD", TypedSecrets.mark, TypedSecrets.mark,
                                                   TypedSecrets.mark, TypedSecrets.mark, TypedSecrets.mark,
                                                   "ada@example.org", "(empty)"])
    }

    func testAHiddenValueStillCountsAsAChange() throws {
        XCTAssertNotEqual(try made([("API token", "one")]), try made([("API token", "two")]))
        XCTAssertEqual(try made([("To", "Ada")]), try made([("To", "Ada")]))
    }

    func testItIsCutAndSaysSo() throws {
        let receipt = try made((0..<50).map { ("f\($0)", String(repeating: "x ", count: 400)) })
        XCTAssertEqual(receipt.rows.count, FormReceipt.mostRows)
        XCTAssertEqual(receipt.more, 20)
        XCTAssertTrue(receipt.rows[0].value.hasSuffix("(800 characters)"))
        XCTAssertTrue(receipt.footnote(after: false).contains("20 more fields are not listed"))
        XCTAssertNotEqual(receipt, try made((0..<49).map { ("f\($0)", String(repeating: "x ", count: 400)) }))
    }

    func testItNeverClaimsToBeTheWholeRequest() throws {
        let receipt = try made([("To", "Ada")])
        for after in [false, true] {
            XCTAssertTrue(receipt.footnote(after: after).contains("This isn't the whole request"))
        }
        XCTAssertTrue(receipt.footnote(after: false).contains("nothing is pressed"))
        XCTAssertTrue(receipt.footnote(after: true).contains("may not be what is sent"))
    }

    func testDirectionMarksCannotRearrangeAValue() throws {
        XCTAssertFalse(try made([("To", "Ada\u{202E}gro.elpmaxe")]).rows[0].value.contains("\u{202E}"))
    }

    // MARK: - in a page

    private func page(_ html: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 900), configuration: configuration)
        PageRoom.shared.made().contentView?.addSubview(web)
        web.loadHTMLString(html, baseURL: URL(string: "https://agent-test.invalid/"))
        for _ in 0..<100 where web.isLoading || web.url == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        return web
    }

    private func run(_ web: WKWebView, _ script: String) async throws -> [String: Any] {
        let value = try await web.evaluateJavaScript(script, contentWorld: Web.world)
        let text = try XCTUnwrap(value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private let form = """
        <!doctype html><form method=post action="/send">
        <input name=elements value=clobber>
        <label>To <input name=to value="Ada"></label>
        <label>Password <input type=password name=pw value="hunter2"></label>
        <label>Shown <input type=password id=shown name=shown value="opensesame"></label>
        <label>Card <input autocomplete="cc-number" name=cc value="4242424242424242"></label>
        <label>Expiry <select autocomplete="cc-exp-month" name=em><option>11</option></select></label>
        <label>One time <input autocomplete="one-time-code" name=o value="987654"></label>
        <input type=hidden name=csrf value="tok-hidden">
        <input name=offscreen value="not-drawn" style="display:none">
        <label>Size <select name=size><option>S</option><option selected>Large</option></select></label>
        <label><input type=checkbox name=news checked> Newsletter</label>
        <label><input type=checkbox name=spam> Spam</label>
        <input disabled name=off value="never-sent">
        <button id=go>Send</button></form>
        """

    func testOnlyOrdinaryFieldsAreReadOut() async throws {
        let web = try await page(form)
        defer { web.removeFromSuperview() }
        // Seen once as a password, then shown as text: still left out.
        _ = try await run(web, PageScripts.read(key: "__test", snap: 1, most: 50, longest: 100, text: false))
        _ = try await web.evaluateJavaScript("document.getElementById('shown').type = 'text'; true")
        let out = try await run(web, PageScripts.sending(to: "https://agent-test.invalid/send"))
        let all = String(decoding: try JSONSerialization.data(withJSONObject: out), as: UTF8.self)
        for kept in ["hunter2", "opensesame", "4242424242424242", "987654", "tok-hidden", "not-drawn", "never-sent"] {
            XCTAssertFalse(all.contains(kept), "\(kept) left the page")
        }
        let receipt = try XCTUnwrap(FormReceipt(out["receipt"]))
        XCTAssertEqual(receipt.rows.map(\.value), ["clobber", "Ada", "Large", "ticked"])
        XCTAssertEqual(receipt.withheld, 7)
    }

    func testAValueChangedAfterTheCardIsNoticed() async throws {
        let web = try await page(form)
        defer { web.removeFromSuperview() }
        let script = PageScripts.sending(to: "https://agent-test.invalid/send")
        let first = try await run(web, script)
        // A hidden token renewing itself changes nothing that was shown.
        _ = try await web.evaluateJavaScript("document.querySelector('[name=csrf]').value = 'tok-two'; true")
        let renewed = try await run(web, script)
        XCTAssertEqual(FormReceipt(first["receipt"]), FormReceipt(renewed["receipt"]))
        _ = try await web.evaluateJavaScript("document.querySelector('[name=to]').value = 'Mallory'; true")
        let changed = try await run(web, script)
        XCTAssertNotEqual(FormReceipt(first["receipt"]), FormReceipt(changed["receipt"]))
    }

    func testNoTableWhereTheFormCannotBeTold() async throws {
        let web = try await page("<!doctype html><form method=post action=/a></form><form method=post action=/a></form>")
        defer { web.removeFromSuperview() }
        for address in ["https://agent-test.invalid/a", "https://agent-test.invalid/b"] {
            let out = try await run(web, PageScripts.sending(to: address))
            XCTAssertNil(FormReceipt(out["receipt"]))
        }
    }

    /// The table is for the card alone: what it needs is not part of what
    /// the gate decides by.
    func testTheGateDoesNotLookAtIt() {
        let with = AgentGate.Target(["tag": "button", "submits": true, "method": "post", "receipt": ["rows": []]])
        let without = AgentGate.Target(["tag": "button", "submits": true, "method": "post"])
        XCTAssertEqual(with, without)
    }
}
