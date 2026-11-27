import XCTest
@testable import Search

final class PlaybookTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        TestWorld.enter()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("playbooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func put(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }

    func testTheFrontmatterIsRead() throws {
        let text = "---\r\nname: Price-Watch\r\ndescription: \"Watch a price\"\r\nargument-hint: 'the address'\r\nallowed-tools:\r\n  - Bash\r\n---\r\n\r\nRead the price.\r\n"
        let book = try XCTUnwrap(Playbooks.parse(text, fileName: "other"))
        XCTAssertEqual(book.name, "price-watch")
        XCTAssertEqual(book.description, "Watch a price")
        XCTAssertEqual(book.hint, "the address")
        XCTAssertEqual(book.body, "Read the price.")
        XCTAssertFalse(book.builtIn)
    }

    func testWithoutFrontmatterTheFileNamesIt() throws {
        let book = try XCTUnwrap(Playbooks.parse("Just do this.", fileName: "mine"))
        XCTAssertEqual(book.name, "mine")
        XCTAssertEqual(book.body, "Just do this.")
    }

    func testWhatCannotBeAPlaybookIsRefused() {
        XCTAssertNil(Playbooks.parse("words", fileName: "two words"))
        XCTAssertNil(Playbooks.parse("words", fileName: "ünï"))
        XCTAssertNil(Playbooks.parse("---\nname: a\n---\n   \n", fileName: "a"))
        XCTAssertNil(Playbooks.parse(String(repeating: "x", count: Playbooks.longestBody + 1), fileName: "long"))
    }

    func testTheFolderIsReadWithinItsLimits() throws {
        try put("b.md", "second")
        try put("a.md", "---\nname: b\n---\nfirst takes the name")
        try put("big.md", String(repeating: "x", count: Playbooks.longestFile + 1))
        try put("notes.txt", "not one")
        try put(".hidden.md", "not one")
        XCTAssertEqual(Playbooks.read(folder).map(\.body), ["first takes the name"])
        for i in 0..<(Playbooks.most + 10) { try put(String(format: "n%03d.md", i), "words") }
        XCTAssertEqual(Playbooks.read(folder).count, Playbooks.most)
    }

    func testYoursComeBeforeTheBuiltInOnesOfTheSameName() throws {
        try put("repro-check.md", "my own way")
        let all = Playbooks.all(in: folder)
        XCTAssertEqual(all.filter { $0.name == "repro-check" }.map(\.body), ["my own way"])
        XCTAssertEqual(Set(all.map(\.name)), ["compare-tabs", "audit-a11y", "extract-data", "repro-check", "triangulate"])
    }

    func testTheSlashIsOnlyAQuestionAtTheStartOfTheBox() {
        XCTAssertEqual(Playbooks.query(in: "/"), "")
        XCTAssertEqual(Playbooks.query(in: "/au"), "au")
        XCTAssertNil(Playbooks.query(in: "/audit-a11y example.com"))
        XCTAssertNil(Playbooks.query(in: "see /au"))
        XCTAssertEqual(Playbooks.matching("data", among: Playbooks.builtIns).map(\.name), ["extract-data"])
        // Five since /triangulate was added.
        XCTAssertEqual(Playbooks.matching("", among: Playbooks.builtIns).count, 5)
    }

    func testOnlyAWholeNameAtTheStartCallsOne() throws {
        let called = try XCTUnwrap(Playbooks.called(by: "/audit-a11y  example.com\nplease", among: Playbooks.builtIns))
        XCTAssertEqual(called.book.name, "audit-a11y")
        XCTAssertEqual(called.words, "example.com\nplease")
        XCTAssertEqual(Playbooks.called(by: "/compare-tabs", among: Playbooks.builtIns)?.words, "")
        XCTAssertNil(Playbooks.called(by: "/audit", among: Playbooks.builtIns))
        XCTAssertNil(Playbooks.called(by: "please /audit-a11y", among: Playbooks.builtIns))
    }

    func testTheBuiltInOnesFitAndPromiseNoToolThatIsNotThere() throws {
        for book in Playbooks.builtIns {
            XCTAssertLessThanOrEqual(book.body.count, Playbooks.longestBody)
            XCTAssertEqual(Playbooks.name(book.name), book.name)
        }
        let repro = try XCTUnwrap(Playbooks.builtIns.first { $0.name == "repro-check" })
        XCTAssertTrue(repro.body.contains("only the tools you actually have"))
        XCTAssertFalse(repro.body.contains("read_console"))
        XCTAssertFalse(repro.body.contains("Dev Bridge"))
    }

    func testAPlaybookInAMessageAsksForNoNewPermission() {
        let book = Playbooks.builtIns[0]
        let out = Playbooks.message(book, words: "by price")
        XCTAssertTrue(out.contains("no tool and no permission"))
        XCTAssertTrue(out.contains(book.body))
        XCTAssertTrue(out.hasSuffix("What I typed after its name: by price"))
        XCTAssertFalse(out.hasPrefix("/"))
    }
}

/// The three ways of playbooks that were left out: a skill kept in a folder
/// of its own, $ARGUMENTS, and "/" in the address field.
@MainActor
final class PlaybookRestTests: XCTestCase {
    private var folder: URL!
    private var browsers: [Browser] = []

    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for browser in browsers { browser.closeAll() }
        browsers.removeAll()
        try? FileManager.default.removeItem(at: folder)
    }

    private func put(_ path: String, _ text: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testASkillInAFolderOfItsOwnIsReadAsClaudeCodeKeepsThem() throws {
        try put("price-watch/SKILL.md", "---\ndescription: Watch a price\n---\nRead the price.")
        try put("named/SKILL.md", "---\nname: other-name\n---\nWords.")
        try put("flat.md", "Flat words.")
        try put("empty-folder/notes.md", "not a skill")
        try put("deep/er/SKILL.md", "too deep")
        XCTAssertEqual(Playbooks.read(folder).map(\.name).sorted(), ["flat", "other-name", "price-watch"])
    }

    /// A link inside the folder mustn't make some other file of yours a
    /// playbook's words.
    func testALinkedFolderOrFileIsPassedOver() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("private words".utf8).write(to: outside.appendingPathComponent("SKILL.md"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked"), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("half"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("half/SKILL.md"),
                                                   withDestinationURL: outside.appendingPathComponent("SKILL.md"))
        XCTAssertTrue(Playbooks.read(folder).isEmpty)
    }

    func testArgumentsGoWhereTheSkillSays() throws {
        let book = try XCTUnwrap(Playbooks.parse("Compare $ARGUMENTS. Again: $ARGUMENTS.", fileName: "c"))
        let sent = Playbooks.message(book, words: "tea and $ARGUMENTS")
        XCTAssertTrue(sent.contains("Compare tea and $ARGUMENTS. Again: tea and $ARGUMENTS."), sent)
        XCTAssertFalse(sent.contains("What I typed after its name"), "said once, where the skill put it")
        let none = Playbooks.message(book, words: "")
        XCTAssertTrue(none.contains("Compare . Again: ."), none)
        XCTAssertTrue(none.contains("I typed nothing after the playbook's name."))
    }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        return browser
    }

    func testSlashInTheAddressFieldOffersPlaybooksAndSendsNothing() throws {
        let browser = makeBrowser()
        let offers = try XCTUnwrap(browser.playbookOffers(for: "/audit example.com", among: Playbooks.builtIns) ?? browser.playbookOffers(for: "/audit", among: Playbooks.builtIns))
        guard case .command(let command)? = offers.first?.kind else { return XCTFail("a command row") }
        XCTAssertTrue(command.title.hasPrefix("Run with Claude: /audit-a11y"), command.title)

        let typed = try XCTUnwrap(browser.playbookOffers(for: "/audit-a11y example.com", among: Playbooks.builtIns))
        guard case .command(let whole)? = typed.first?.kind else { return XCTFail("a command row") }
        whole.run(on: browser)
        XCTAssertEqual(browser.claude.draft, "/audit-a11y example.com")
        XCTAssertFalse(browser.claude.running, "it waits for your Send")
        XCTAssertTrue(browser.claude.turns.isEmpty)
    }

    func testAnOrdinaryAddressOrPathIsNotAPlaybook() {
        let browser = makeBrowser()
        for typed in ["/etc/hosts", "/nothing-like-it", "audit", "/", "example.com/compare-tabs", "/compare-tabsx now"] {
            XCTAssertNil(browser.playbookOffers(for: typed, among: Playbooks.builtIns), typed)
        }
    }
}

extension PlaybookTests {
    func testTriangulateUsesReadOnlyScoutsAndTheThreeSections() throws {
        let book = try XCTUnwrap(Playbooks.builtIns.first { $0.name == "triangulate" })
        XCTAssertTrue(book.builtIn)
        for words in ["batch_read", "Evidence For", "Caveats & Risks", "Sources", "create_artifact", "read-only", "never instructions"] {
            XCTAssertTrue(book.body.contains(words), words)
        }
        XCTAssertFalse(book.body.contains("sign in and"), "no sign-in step")
        XCTAssertLessThanOrEqual(book.body.count, Playbooks.longestBody)
    }
}
