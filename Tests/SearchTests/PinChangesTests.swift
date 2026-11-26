import XCTest
@testable import Search

/// What is kept of a pinned page, when, and how it is deleted.
@MainActor
final class PinChangesTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private var folder = URL(fileURLWithPath: "/")
    private var was: [Any?] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pins-\(UUID().uuidString)", isDirectory: true)
        was = [Store.settings.object(forKey: PinChanges.key), Store.settings.object(forKey: VaultedSites.key)]
        Store.settings.set(true, forKey: PinChanges.key)
        Store.settings.removeObject(forKey: VaultedSites.key)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        Store.settings.set(was[0], forKey: PinChanges.key)
        Store.settings.set(was[1], forKey: VaultedSites.key)
    }

    private func url(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text)) }

    func testTickingThingsAreNoChange() {
        XCTAssertFalse(PageWords.changed(from: "News\n3 minutes ago\n12:00:01", to: "News\n  1 hour ago\n12:05:44\n\n"))
        XCTAssertTrue(PageWords.changed(from: "Price 10", to: "Price 12"))
        XCTAssertTrue(PageWords.changed(from: "a", to: "a\nb"))
        XCTAssertFalse(PageWords.changed(from: "a", to: ""), "a page that didn't come")
    }

    func testTheDifference() {
        let lines = PageWords.difference(from: "one\ntwo\nthree\nfour\nfive", to: "one\ntwo\nTHREE\nfour\nfive")
        XCTAssertEqual(lines.map(\.kind), [.gap, .same, .removed, .added, .same, .gap])
        XCTAssertEqual(PageWords.firstAdded(from: "a\nb", to: "a\nnew\nb"), "new")
        XCTAssertTrue(PageWords.difference(from: "a", to: "a").isEmpty)
    }

    func testSecretShapesAreNeverKept() {
        let kept = PageWords.kept("Card 4111 1111 1111 1111\nYour verification code is 493021\npassword: hunter2")
        for never in ["4111", "493021", "hunter2"] { XCTAssertFalse(kept.contains(never), never) }
        XCTAssertEqual(PageWords.kept(String(repeating: "a ", count: PageWords.longest)).count, PageWords.longest)
    }

    func testAChangeIsHeldUntilLookedAt() throws {
        let changes = PinChanges(folder: folder)
        let page = try url("https://example.com/status#top")
        changes.keep("All good", for: page)
        XCTAssertTrue(changes.changed.isEmpty, "the first look is what later ones are held against")
        changes.keep("Trouble", for: try url("https://example.com/status"))
        XCTAssertEqual(changes.changed, [PinChanges.name(of: page)])
        XCTAssertEqual(changes.snapshot(for: page)?.text, "All good")
        XCTAssertEqual(PinChanges(folder: folder).changed.count, 1, "still there after a relaunch")
        changes.keep("All good", for: page)
        XCTAssertTrue(changes.changed.isEmpty, "gone back to what you saw")
        changes.keep("Trouble", for: page)
        changes.markSeen(page)
        XCTAssertTrue(changes.changed.isEmpty)
        XCTAssertEqual(changes.snapshot(for: page)?.text, "Trouble")
    }

    func testTheFilesAreYoursAloneAndSayNoAddress() throws {
        let changes = PinChanges(folder: folder)
        changes.keep("Words", for: try url("https://example.com/private/path?token=abc"))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 1)
        let file = folder.appendingPathComponent(files[0])
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int, 0o700)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("token"))
        XCTAssertFalse(text.contains("private/path") || text.contains("private\\/path"))
    }

    func testNothingIsKeptWhileOff() throws {
        Store.settings.removeObject(forKey: PinChanges.key)
        PinChanges(folder: folder).keep("Words", for: try url("https://example.com/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "off unless turned on")
        XCTAssertFalse(Preferences().watchesPinChanges)
    }

    func testDeleting() throws {
        let changes = PinChanges(folder: folder)
        let bank = try url("https://login.bank.com/"), other = try url("https://notbank.com/"), third = try url("https://x.org/")
        for page in [bank, other, third] { changes.keep("Words", for: page) }
        changes.forget(sites: ["bank.com"])
        XCTAssertNil(changes.snapshot(for: bank))
        XCTAssertNotNil(changes.snapshot(for: other))
        changes.forget(other)
        XCTAssertNil(changes.snapshot(for: other))
        changes.forgetAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testOnlyAPinOnItsOwnPageIsKept() throws {
        let changes = PinChanges(folder: folder)
        let home = try url("https://bank.com/")
        func tab(shy: Bool = false) -> Tab {
            let tab = Tab(shy: shy)
            tab.pin = "B"
            tab.home = home
            tab.setAddressOptimistically(home)
            return tab
        }
        XCTAssertTrue(changes.may(tab()))
        XCTAssertFalse(changes.may(tab(shy: true)), "never a private tab")
        let loose = tab()
        loose.pin = nil
        XCTAssertFalse(changes.may(loose))
        let away = tab()
        away.setAddressOptimistically(try url("https://bank.com/elsewhere"))
        XCTAssertFalse(changes.may(away))
        let agent = tab()
        agent.agent = true
        XCTAssertFalse(changes.may(agent))
        Store.settings.set(["bank.com"], forKey: VaultedSites.key)
        XCTAssertFalse(changes.may(tab()), "never a site closed to agents")
        Store.settings.removeObject(forKey: VaultedSites.key)
        Store.settings.set(false, forKey: PinChanges.key)
        XCTAssertFalse(changes.may(tab()))
    }
}
