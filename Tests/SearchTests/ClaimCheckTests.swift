import XCTest
@testable import Search

/// A card's words looked for in what was read from its sources: a text
/// match, said as one.
@MainActor
final class ClaimCheckTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private func found(_ claim: String, _ source: String) -> Bool {
        ClaimCheck.matches(ClaimCheck.tokens(claim), in: ClaimCheck.tokens(source))
    }

    func testWordsAndNumbers() {
        let source = "The Basic plan costs $1,200 a year. It includes 15 seats and e-mail support. Café opening: 9.30."
        XCTAssertTrue(found("$1200", source))
        XCTAssertTrue(found("Basic plan costs 1,200 a year", source))
        XCTAssertTrue(found("cafe opening 9.30", source))
        XCTAssertFalse(found("5 seats", source), "5 isn't in 15")
        XCTAssertFalse(found("$1300", source))
        XCTAssertFalse(found("phone support", source))
    }

    func testANotMustBeThere() {
        XCTAssertFalse(found("Refunds are not offered after purchase", "Refunds are offered after purchase."))
    }

    func testWordsFarApartAreNotAMatch() {
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 60)
        XCTAssertFalse(found("tent weighs 900 grams", "The tent is green. " + filler + "A stove weighs 900 grams."))
        XCTAssertTrue(found("tent weighs 900 grams", filler + "This tent, packed, weighs about 900 grams."))
    }

    private let tab = UUID()
    private var source: Artifact.Source { Artifact.Source(tab: tab, site: "a.example", address: "https://a.example/x#top") }
    private var key: SourceSnapshots.Key { SourceSnapshots.Key(tab: tab, page: "https://a.example/x") }

    private func table(_ cells: [(String, Bool)], evidence: String?, length: Int? = nil) -> Artifact {
        var artifact = Artifact(kind: .table, title: "t", columns: cells.map { _ in "c" })
        artifact.rows = [cells.map { Artifact.Cell(text: $0.0, source: $0.1 ? source : nil) }]
        if let evidence {
            var kept = SourceSnapshots()
            kept.keep(evidence, at: 0, of: length ?? evidence.utf16.count, tab: tab, page: "https://a.example/x")
            artifact.evidence = kept.pages
        }
        return artifact
    }

    func testEachVerdict() {
        let made = table([("Map $18", true), ("Compass $9", true), ("Rope", false), ("Yes", true), ("", true)], evidence: "Map $18 in stock")
        XCTAssertEqual(ClaimCheck.check(made).map(\.verdict), [.found, .notFound, .noSource], "nothing to look for in Yes or an empty cell")
        XCTAssertEqual(ClaimCheck.check(table([("Compass", true)], evidence: "Map", length: 9000)).first?.verdict, .notInPartRead)
        XCTAssertEqual(ClaimCheck.check(table([("Compass", true)], evidence: nil)).first?.verdict, .noText)
    }

    func testASectionIsCheckedSentenceBySentence() {
        var artifact = Artifact(kind: .brief, title: "t")
        artifact.sections = [Artifact.Section(heading: "h", body: "The tent weighs 900 grams. It costs 40 pounds.", source: source)]
        var kept = SourceSnapshots()
        kept.keep("This tent weighs 900 grams.", at: 0, of: 27, tab: tab, page: key.page)
        artifact.evidence = kept.pages
        let finding = ClaimCheck.check(artifact).first
        XCTAssertEqual(finding?.words, "1 of 2 sentences not found in the source")
    }

    func testItNeverSaysTrueOrFalse() {
        let all: [ClaimCheck.Verdict] = [.found, .notFound, .notInPartRead, .noText, .noSource]
        let said = all.map(\.words) + [ClaimCheck.summary(ClaimCheck.check(table([("x 1", true)], evidence: "y")))]
        for words in said {
            XCTAssertNil(words.range(of: #"\b(true|false|verified|correct|wrong claim|ungrounded)\b"#,
                                     options: [.regularExpression, .caseInsensitive]), words)
        }
        XCTAssertTrue(said.last?.hasPrefix("Text match only") == true)
    }

    func testAPageReadInPiecesIsPutTogether() {
        var kept = SourceSnapshots()
        kept.keep("alpha br", at: 0, of: 16, tab: tab, page: "p")
        XCTAssertEqual(kept.page(tab: tab, address: "p")?.read.whole, false)
        kept.keep("avo done", at: 8, of: 16, tab: tab, page: "p")
        XCTAssertEqual(kept.page(tab: tab, address: "p")?.read.text, "alpha bravo done")
        XCTAssertEqual(kept.page(tab: tab, address: "p")?.read.whole, true)
    }

    func testWhatIsKeptIsBounded() {
        var kept = SourceSnapshots()
        for n in 0..<(SourceSnapshots.mostPages + 5) { kept.keep("x", at: 0, of: 1, tab: tab, page: "p\(n)") }
        XCTAssertEqual(kept.pages.count, SourceSnapshots.mostPages)
        XCTAssertNil(kept.page(tab: tab, address: "p0"))
        let big = String(repeating: "a", count: SourceSnapshots.mostPerPage + 1)
        kept.keep(big, at: 0, of: big.count, tab: tab, page: "big")
        XCTAssertNil(kept.page(tab: tab, address: "big"))
    }

    func testACardKeepsWhatHadBeenReadWhenItWasMadeAndNewChatForgets() {
        let session = ClaudeSession(world: nil)
        session.seed(question: "q", answer: "", steps: [])
        let address = URL(string: "https://a.example/x")
        session.read("Map $18", at: 0, of: 7, tab: tab, address: address)
        XCTAssertTrue(session.add(table([("Map $18", true)], evidence: nil)))
        session.read("Sold out", at: 0, of: 8, tab: tab, address: address)
        let card = session.turns.last?.artifacts.last
        XCTAssertEqual(card.map { ClaimCheck.check($0).first?.verdict }, .found, "what it was made from")
        XCTAssertFalse(card?.markdown.contains("in stock") ?? true)
        session.newChat()
        XCTAssertTrue(session.snapshots.pages.isEmpty)
    }
}
