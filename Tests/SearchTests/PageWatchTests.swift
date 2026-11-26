import XCTest
@testable import Search

/// Watched pages: only the ones picked, only while switched on, what a look
/// may load, and how they are deleted. No look is made here.
@MainActor
final class PageWatchTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private var folder = URL(fileURLWithPath: "/")
    private var was: [Any?] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        was = [Store.settings.object(forKey: PageWatches.key), Store.settings.object(forKey: VaultedSites.key)]
        Store.settings.set(true, forKey: PageWatches.key)
        Store.settings.removeObject(forKey: VaultedSites.key)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        Store.settings.set(was[0], forKey: PageWatches.key)
        Store.settings.set(was[1], forKey: VaultedSites.key)
    }

    private var file: URL { folder.appendingPathComponent("watches.json") }
    private func url(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text)) }

    private func make(_ told: @escaping @MainActor (Watch) -> Void = { _ in }) -> PageWatches {
        PageWatches(file: file, live: false, notify: told)
    }

    func testOffUnlessTurnedOn() throws {
        Store.settings.removeObject(forKey: PageWatches.key)
        XCTAssertFalse(Preferences().watchesPages)
        let watches = make()
        XCTAssertFalse(watches.add(try url("https://example.com/"), title: "x", every: .hour))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testWhatMayBeWatched() throws {
        let watches = make()
        Store.settings.set(["bank.com"], forKey: VaultedSites.key)
        for never in ["https://login.bank.com/", "file:///etc/hosts", "https://me:pw@example.com/", "about:blank"] {
            XCTAssertFalse(watches.may(try url(never)), never)
        }
        XCTAssertTrue(watches.may(try url("https://notbank.com/")))
        let page = try url("https://example.com/")
        let tab = Tab(shy: true)
        tab.setAddressOptimistically(page)
        XCTAssertFalse(watches.offers(tab), "never a private tab")
        let plain = Tab()
        plain.setAddressOptimistically(page)
        XCTAssertTrue(watches.offers(plain))
        plain.agent = true
        XCTAssertFalse(watches.offers(plain))
    }

    func testAChangeIsToldOnce() throws {
        var told: [Watch] = []
        let watches = make { told.append($0) }
        XCTAssertTrue(watches.add(try url("https://example.com/"), title: "x", every: .quarter))
        let id = try XCTUnwrap(watches.watches.first?.id)
        XCTAssertFalse(watches.looked(id, said: "Closed"), "the first look is what later ones are held against")
        XCTAssertFalse(watches.looked(id, said: nil), "a failed look changes nothing")
        XCTAssertFalse(watches.looked(id, said: "   "), "nor an empty one")
        XCTAssertTrue(watches.looked(id, said: "Closed\nNow open"))
        XCTAssertFalse(watches.looked(id, said: "Closed\nNow open"))
        XCTAssertEqual(told.count, 1)
        XCTAssertEqual(told.first?.found, "Now open")
        XCTAssertEqual(make().watches.first?.text, "Closed\nNow open")
    }

    func testSecretShapesNeverReachTheFile() throws {
        let watches = make()
        watches.add(try url("https://example.com/"), title: "x", every: .hour)
        watches.looked(try XCTUnwrap(watches.watches.first?.id), said: "Card 4111 1111 1111 1111 code: otp 493021")
        let kept = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(kept.contains("4111"))
        XCTAssertFalse(kept.contains("493021"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    }

    func testDue() throws {
        var watch = Watch(url: try url("https://example.com/"), title: "", every: .hour)
        let now = Date()
        XCTAssertTrue(watch.isDue(now))
        watch.lastChecked = now.addingTimeInterval(-1800)
        XCTAssertFalse(watch.isDue(now))
        watch.lastChecked = now.addingTimeInterval(-3500)
        XCTAssertTrue(watch.isDue(now))
    }

    func testDeletingAndTheLimit() throws {
        let watches = make()
        for n in 0..<PageWatches.most {
            XCTAssertTrue(watches.add(try url("https://example.com/\(n)"), title: "", every: .hour))
        }
        XCTAssertFalse(watches.add(try url("https://example.com/more"), title: "", every: .hour))
        XCTAssertTrue(watches.add(try url("https://example.com/0"), title: "", every: .sixHours), "its interval changed")
        XCTAssertEqual(watches.watches.count, PageWatches.most)
        watches.remove(try XCTUnwrap(watches.watches.first?.id))
        XCTAssertEqual(make().watches.count, PageWatches.most - 1)
        watches.forget(sites: ["example.com"])
        XCTAssertTrue(watches.watches.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        watches.add(try url("https://other.org/"), title: "", every: .hour)
        watches.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testWhatALookMayLoad() throws {
        let watched = try url("https://example.com/")
        func allows(_ text: String, method: String = "GET", main: Bool = true, download: Bool = false) throws -> Bool {
            WatchLook.allows(try url(text), watched: watched, method: method, mainFrame: main, download: download,
                             vaulted: ["bank.com"])
        }
        XCTAssertTrue(try allows("https://example.com/next"))
        XCTAssertFalse(try allows("https://pay.bank.com/"))
        XCTAssertFalse(try allows("https://pay.bank.com/", main: false))
        XCTAssertFalse(try allows("https://example.com/send", method: "POST"))
        XCTAssertFalse(try allows("https://example.com/file", download: true))
        XCTAssertFalse(try allows("mailto:a@example.com"))
        XCTAssertFalse(try allows("data:text/html,x"))
        XCTAssertTrue(try allows("about:blank", main: false))
        XCTAssertFalse(try allows("http://192.168.1.1/"), "a public page can't send a look inside")
        XCTAssertTrue(WatchLook.allows(try url("http://192.168.1.1/b"), watched: try url("http://192.168.1.1/"),
                                       method: "GET", mainFrame: true, download: false, vaulted: []))
    }

    func testTheWordsLookedForOnThePage() {
        XCTAssertEqual(PageWatches.needle("## Now **open**"), "Now open")
        XCTAssertEqual(PageWatches.needle("- a \\*star\\*"), "a *star*")
        XCTAssertEqual(PageWatches.needle("| Price | 10 |"), "Price")
    }
}
