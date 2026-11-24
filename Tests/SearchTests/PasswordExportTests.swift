import XCTest
@testable import Search

final class PasswordExportTests: XCTestCase {
    private func item(_ host: String, _ user: String, _ password: String, clear: Bool = false, _ extras: Extras = Extras()) -> Item {
        Item(host: host, user: user, password: password, extras: extras, used: nil, clear: clear)
    }

    func testCSVQuotesWhatNeedsIt() {
        var extras = Extras()
        extras.notes = "line one\nline \"two\""
        let text = PasswordExport.csv([item("example.com", "a@b.c", "pa,ss\"word", extras)])
        XCTAssertTrue(text.hasPrefix("name,url,username,password,note,otpauth\r\n"))
        XCTAssertTrue(text.contains("\"pa,ss\"\"word\""))
    }

    func testCSVComesBackThroughTheImporter() throws {
        var extras = Extras()
        extras.notes = "a note, with a comma"
        extras.totp = "JBSWY3DPEHPK3PXP"
        let text = PasswordExport.csv([item("example.com", "me", "p,\"w\"\n2", extras), item("old.test", "x", "plain", clear: true)])
        let parsed = try XCTUnwrap(PasswordImport.parse(csv: text))
        XCTAssertEqual(parsed.candidates.count, 2)
        let first = try XCTUnwrap(parsed.candidates.first { $0.host == "example.com" })
        XCTAssertEqual(first.password, "p,\"w\"\n2")
        XCTAssertEqual(first.extras.notes, "a note, with a comma")
        XCTAssertEqual(first.extras.totp, "JBSWY3DPEHPK3PXP")
        XCTAssertTrue(try XCTUnwrap(parsed.candidates.first { $0.host == "old.test" }).clear)
    }

    func testBackupRoundTrip() throws {
        var extras = Extras()
        extras.title = "Mail"
        extras.totp = "JBSWY3DPEHPK3PXP"
        extras.urls = ["https://mail.example.com"]
        extras.changed = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try XCTUnwrap(PasswordExport.seal([item("example.com", "me", "s3cret ✓", extras)], passphrase: "correct horse", rounds: 1_000))
        XCTAssertTrue(PasswordExport.isVault(data))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("s3cret"))
        let parsed = try PasswordExport.open(data, passphrase: "correct horse").get()
        let back = try XCTUnwrap(parsed.candidates.first)
        XCTAssertEqual(back.host, "example.com")
        XCTAssertEqual(back.password, "s3cret ✓")
        XCTAssertEqual(back.extras, extras)
    }

    func testWrongPassphraseAndShortOnesAreRefused() throws {
        let data = try XCTUnwrap(PasswordExport.seal([item("example.com", "me", "pw")], passphrase: "correct horse", rounds: 1_000))
        XCTAssertEqual(PasswordExport.open(data, passphrase: "wrong horse").failureValue, .wrongPassphrase)
        XCTAssertNil(PasswordExport.seal([item("example.com", "me", "pw")], passphrase: "short", rounds: 1_000))
    }

    func testAChangedFileDoesNotOpen() throws {
        var data = try XCTUnwrap(PasswordExport.seal([item("example.com", "me", "pw")], passphrase: "correct horse", rounds: 1_000))
        var text = String(decoding: data, as: UTF8.self)
        // Flip a byte inside the sealed box.
        if let range = text.range(of: "\"box\" : \"") {
            let at = text.index(range.upperBound, offsetBy: 20)
            let flipped: Character = text[at] == "A" ? "B" : "A"
            text.replaceSubrange(at...at, with: String(flipped))
        }
        data = Data(text.utf8)
        XCTAssertEqual(PasswordExport.open(data, passphrase: "correct horse").failureValue, .wrongPassphrase)
    }

    func testNotAVaultAndTooManyRounds() {
        XCTAssertFalse(PasswordExport.isVault(Data("name,url\n".utf8)))
        XCTAssertEqual(PasswordExport.open(Data("{}".utf8), passphrase: "whatever").failureValue, .notAVault)
        let greedy = #"{"format":"cairnvault","version":1,"kdf":"pbkdf2-sha256","rounds":900000000,"salt":"AAAA","box":"AAAA"}"#
        XCTAssertEqual(PasswordExport.open(Data(greedy.utf8), passphrase: "whatever").failureValue, .notAVault)
    }
}

private extension Result {
    var failureValue: Failure? { if case .failure(let error) = self { return error } else { return nil } }
}
