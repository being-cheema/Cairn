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
        XCTAssertEqual(Set(all.map(\.name)), ["compare-tabs", "audit-a11y", "extract-data", "repro-check"])
    }

    func testTheSlashIsOnlyAQuestionAtTheStartOfTheBox() {
        XCTAssertEqual(Playbooks.query(in: "/"), "")
        XCTAssertEqual(Playbooks.query(in: "/au"), "au")
        XCTAssertNil(Playbooks.query(in: "/audit-a11y example.com"))
        XCTAssertNil(Playbooks.query(in: "see /au"))
        XCTAssertEqual(Playbooks.matching("data", among: Playbooks.builtIns).map(\.name), ["extract-data"])
        XCTAssertEqual(Playbooks.matching("", among: Playbooks.builtIns).count, 4)
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
