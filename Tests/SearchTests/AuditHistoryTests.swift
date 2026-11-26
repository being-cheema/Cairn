import XCTest
@testable import Search

/// What an audit found Task History keeping that it shouldn't have.
@MainActor
final class AuditHistoryTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    // MARK: - secrets in their common written forms

    /// Made up, and put together here so a scanner has nothing to find.
    private func made(_ parts: String...) -> String { parts.joined() }

    private func assertHidden(_ typed: String, _ gone: String, file: StaticString = #filePath, line: UInt = #line) {
        let kept = TaskRecord(prompt: typed, model: nil).prompt
        XCTAssertFalse(kept.contains(gone), "\(typed) -> \(kept)", file: file, line: line)
        XCTAssertTrue(kept.contains(TypedSecrets.mark), "\(typed) -> \(kept)", file: file, line: line)
    }

    func testASettingsNameAroundTheWordDoesNotHideItFromUs() {
        assertHidden(made("set DB_", "PASSWORD=", "hunter2 and retry"), "hunter2")
        assertHidden(made("client_", "secret=", "abc123zz"), "abc123zz")
        assertHidden(made("AWS_SECRET_", "ACCESS_KEY=", "wJalrXUtnFEMIK7MDENG"), "wJalrXUtnFEMIK7MDENG")
        assertHidden(made("GITHUB_", "TOKEN: ", "zzz999yyy888"), "zzz999yyy888")
    }

    func testAQuotedNameAsInJSONIsSeen() {
        assertHidden(made("send {\"pass", "word\": \"correct horse\"} to it"), "correct horse")
        assertHidden(made("{'api_", "key':'q1w2e3r4t5'}"), "q1w2e3r4t5")
    }

    func testMoreShapesOfKey() {
        let tail = String(repeating: "Ab3", count: 12)
        assertHidden("use " + made("sk_", "live_") + tail, tail)
        assertHidden("use " + made("rk_", "test_") + tail, tail)
        assertHidden("use " + made("AI", "za") + tail, tail)
    }

    func testAQuoteNeverClosedHidesToTheEndOfTheLine() {
        assertHidden(made("pass", "word=\"two words and no end"), "words and no end")
    }

    func testAPasswordInsideAnAddressIsNotKept() {
        assertHidden(made("connect to postgres://me:", "hunter2", "@db.example:5432/x"), "hunter2")
        assertHidden(made("open https://me:", "s3cretzz", "@example.com/"), "s3cretzz")
    }

    func testAPageAddressLosesItsPasswordToo() {
        let kept = AgentRules.url(made("https://me:", "hunter2", "@example.com/a"))
        XCTAssertFalse(kept.contains("hunter2"), kept)
        XCTAssertTrue(kept.contains("example.com/a"), kept)
    }

    func testSentencesThatOnlyMentionTheseWordsStay() {
        for typed in ["why does my secret santa list reset", "what is a token ring network",
                      "mail me@example.com about the password policy", "see https://example.com:8443/docs@v2"] {
            XCTAssertEqual(TaskRecord(prompt: typed, model: nil).prompt, typed)
        }
    }

    // MARK: - one profile's history is its own

    func testEachProfileKeepsItsOwnHistory() {
        let one = TaskLedger.folder(for: UUID()), other = TaskLedger.folder(for: UUID())
        let first = TaskLedger.folder(for: Profile.personalID)
        XCTAssertEqual(first, TaskLedger.folder, "what is already kept stays where it is")
        for folder in [one, other, first] { TaskLedger.removeAll(in: folder) }
        defer { for folder in [one, other, first] { TaskLedger.removeAll(in: folder) } }
        func record(_ words: String) -> TaskRecord {
            var made = TaskRecord(prompt: words, model: nil)
            made.time = Date().addingTimeInterval(1)
            return made
        }
        TaskLedger.save(record("in one"), in: one)
        TaskLedger.save(record("in the other"), in: other)

        XCTAssertEqual(TaskLedger.all(in: one).map(\.prompt), ["in one"])
        XCTAssertTrue(TaskLedger.all(in: first).isEmpty)
        // Clearing the first must not reach inside another's.
        TaskLedger.removeAll(in: first)
        XCTAssertEqual(TaskLedger.all(in: other).map(\.prompt), ["in the other"])
    }
}
