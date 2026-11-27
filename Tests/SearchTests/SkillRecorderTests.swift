import XCTest
import WebKit
@testable import Search

@MainActor
final class SkillRecorderTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private let events: [[String: Any]] = [
        ["k": "open", "url": "https://shop.example/search"],
        ["k": "click", "role": "searchbox", "name": "Search"],
        ["k": "change", "role": "searchbox", "name": "Search", "value": "owls-are-private-1234"],
        ["k": "change", "role": "searchbox", "name": "Search"],
        ["k": "key", "role": "searchbox", "name": "Search", "key": "Enter"],
        ["k": "click", "role": "button", "name": "Add to basket"],
        ["k": "change", "role": "textbox", "name": "Card code", "secret": true],
    ]

    func testTypedLiteralsBecomeParametersAndNeverReachTheFile() {
        let steps = SkillRecording.steps(from: events)
        let made = SkillRecording.markdown(name: "buy-owls", steps: steps)
        XCTAssertEqual(made.parameters, ["search"])
        XCTAssertFalse(made.text.contains("owls-are-private"))
        XCTAssertTrue(made.text.contains("Type <search> into the searchbox named “Search”"))
        XCTAssertTrue(made.text.contains("$ARGUMENTS"))
        XCTAssertTrue(made.text.contains("argument_hint: <search>"))
        XCTAssertEqual(steps.filter { $0.kind == .type }.count, 2, "the search, once, and the code")
        XCTAssertFalse(steps.contains { $0.kind == .click && $0.role == "searchbox" }, "a click into a box is not a step")
    }

    func testASecretBoxIsHandedToThePersonAndNothingOfItIsKept() {
        let made = SkillRecording.markdown(name: "x", steps: SkillRecording.steps(from: events))
        XCTAssertTrue(made.text.contains("don't fill it. Call wait_for_sign_in"))
        XCTAssertEqual(made.parameters.count, 1, "the code box is no parameter")
    }

    func testTheResultLoadsAsAPlaybookAndIsSavedAsAFolderOnlyYouCanRead() throws {
        let made = SkillRecording.markdown(name: "buy-owls", steps: SkillRecording.steps(from: events))
        let book = try XCTUnwrap(Playbooks.parse(made.text, fileName: "buy-owls"))
        XCTAssertEqual(book.name, "buy-owls")
        let folder = Store.file("Skills-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try XCTUnwrap(SkillRecording.save(made.text, as: "buy-owls", in: folder))
        let second = try XCTUnwrap(SkillRecording.save(made.text, as: "buy-owls", in: folder))
        XCTAssertNotEqual(first, second, "never over one that is there")
        let mode = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(Playbooks.read(folder).map(\.name).sorted(), ["buy-owls", "buy-owls-2"])
        XCTAssertNil(SkillRecording.save(made.text, as: "bad name!", in: folder))
    }

    func testAPageScriptIsHeardOnlyForYourOwnEvents() async throws {
        let web = try await {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
            PageRoom.shared.made().contentView?.addSubview(view)
            view.loadHTMLString("<button id=b>Go</button><input type=password aria-label=Pin>", baseURL: URL(string: "https://agent-test.invalid/"))
            for _ in 0..<100 where view.isLoading || view.url == nil { try await Task.sleep(nanoseconds: 50_000_000) }
            return view
        }()
        _ = try await web.evaluateJavaScript(PageScripts.record(), contentWorld: Web.world)
        // A page's own script clicking is not you.
        _ = try await web.evaluateJavaScript("document.getElementById('b').click(); null")
        let said = try await web.evaluateJavaScript(PageScripts.record(), contentWorld: Web.world) as? String
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(said).utf8)) as? [String: Any])
        XCTAssertEqual((out["events"] as? [Any])?.count, 0)
    }
}
