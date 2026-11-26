import XCTest
@testable import Search

/// Phases 5, 6 and 7 were built side by side. These are the places one has to
/// know about another.
@MainActor
final class PhaseSeamTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// A site closed to agents is closed to batch_read and to reading memory.
    func testABlockedSiteIsBlockedForWhatReadsOnItsOwn() {
        let before = Store.settings.stringArray(forKey: VaultedSites.key)
        defer { Store.settings.set(before, forKey: VaultedSites.key) }
        Store.settings.set(["bank.example"], forKey: VaultedSites.key)

        XCTAssertTrue(HostBlock.isBlocked("bank.example"))
        XCTAssertTrue(HostBlock.isBlocked("WWW.Bank.Example."))
        XCTAssertFalse(HostBlock.isBlocked("notbank.example"))
    }

    /// As pin snapshots and watches do: what was kept of it goes.
    func testClosingASiteForgetsWhatMemoryKeptOfIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("seam-\(UUID().uuidString)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "seam-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let memory = ReadingMemory(defaults: defaults, index: MemoryIndex(folder: folder, spotlight: NoSpotlight()))
        memory.turn(true)
        defer { memory.turn(false) }
        for address in ["https://www.bank.example/a", "https://notbank.example/b"] {
            memory.keep(address: address, title: "Heron", text: String(repeating: "A long article about herons. ", count: 40),
                        epoch: memory.index.epoch)
        }
        memory.index.drain()
        XCTAssertEqual(memory.search("herons", limit: 5).count, 2, "both kept, or this test shows nothing")

        memory.forget(sites: ["bank.example"])
        memory.index.drain()
        XCTAssertEqual(memory.search("herons", limit: 5).map(\.address), ["https://notbank.example/b"])
    }

    /// Copy Page as Markdown takes the margin notes with it.
    func testCopiedMarkdownCarriesTheMarginNotes() throws {
        let page = PageMarkdown.Page(markdown: "They fish.", cut: false, title: "Herons", url: nil)
        let copied = try XCTUnwrap(PageMarkdown.copied(page, notes: "## Notes\n\n- Check this."))
        XCTAssertTrue(copied.contains("They fish."))
        XCTAssertTrue(copied.hasSuffix("## Notes\n\n- Check this.\n"), copied)
        XCTAssertFalse(try XCTUnwrap(PageMarkdown.copied(page, notes: nil)).contains("Notes"))
    }
}
