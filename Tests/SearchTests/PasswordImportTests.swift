import XCTest
@testable import Search

/// Passwords files from other managers, read for the preview. No keychain is
/// touched: the plan's lookups and the commit's writes are stand-ins.
final class PasswordImportTests: XCTestCase {
    private func parsed(_ csv: String) throws -> PasswordImport.Parsed {
        try XCTUnwrap(PasswordImport.parse(Data(csv.utf8)))
    }

    func testChromesColumns() throws {
        let p = try parsed("name,url,username,password,note\nExample,https://www.example.com/login,ann,pw1,hello\n")
        XCTAssertEqual(p.source, "Chrome, Edge, Brave or similar")
        XCTAssertEqual(p.candidates.count, 1)
        XCTAssertEqual(p.candidates[0].host, "example.com", "a leading www. is not part of the site")
        XCTAssertEqual(p.candidates[0].user, "ann")
        XCTAssertEqual(p.candidates[0].extras.notes, "hello")
        XCTAssertNil(p.candidates[0].extras.title, "a title that is only the site's name is dropped")
    }

    func testTheApplePasswordsFileKeepsItsCodeKey() throws {
        let p = try parsed("Title,URL,Username,Password,Notes,OTPAuth\nGitHub,https://github.com,ann,pw,,otpauth://totp/GitHub:ann?secret=ABC\n")
        XCTAssertEqual(p.source, "the Passwords app or Safari")
        XCTAssertEqual(p.candidates[0].extras.totp, "otpauth://totp/GitHub:ann?secret=ABC")
        XCTAssertNil(p.candidates[0].extras.title)
    }

    func testBitwardensCSVAndOthers() throws {
        XCTAssertEqual(try parsed("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n,0,login,Mail,n,,0,https://mail.example.com,bob,pw,\n").source, "Bitwarden")
        XCTAssertEqual(try parsed("url,username,password,totp,extra,name,grouping,fav\nhttps://a.example,u,pw,,,A,,0\n").source, "LastPass")
        XCTAssertEqual(try parsed("url,username,password,httpRealm,formActionOrigin,guid\nhttps://a.example,u,pw,,,x\n").source, "Firefox")
        XCTAssertEqual(try parsed("\"Account\",\"Login Name\",\"Password\",\"Web Site\",\"Comments\"\n\"A\",\"u\",\"pw\",\"https://a.example\",\"\"\n").source, "KeePass")
    }

    func testAByteOrderMarkQuotesAndNewlinesInsideFields() throws {
        let p = try parsed("\u{FEFF}name,url,username,password,note\n\"A, Inc\",https://a.example,u,\"pa\"\"ss\",\"line one\nline two\"\n")
        XCTAssertEqual(p.candidates[0].password, "pa\"ss")
        XCTAssertEqual(p.candidates[0].extras.notes, "line one\nline two")
        XCTAssertEqual(p.candidates[0].extras.title, "A, Inc")
    }

    func testRowsThatCantBeTakenSayWhyWithoutTheSecret() throws {
        let p = try parsed("name,url,username,password,note\nA,android://x@com.vendor.app/,u,secret1,\nB,https://b.example,u,,\nC,,u,secret3,\n")
        XCTAssertTrue(p.candidates.isEmpty)
        XCTAssertEqual(p.problems.map(\.why), ["Not a website address", "No password", "No address"])
        XCTAssertFalse(p.problems.contains { $0.why.contains("secret") })
    }

    func testAFileThatIsNotPasswordsIsRefused() {
        XCTAssertNil(PasswordImport.parse(Data("hello world".utf8)))
        XCTAssertNil(PasswordImport.parse(Data("a,b,c\n1,2,3\n".utf8)))
        XCTAssertNil(PasswordImport.parse(Data("{\"nothing\":1}".utf8)))
    }

    func testBitwardensJSON() throws {
        let json = """
        {"items":[
          {"type":1,"name":"Mail","notes":"n","login":{"username":"bob","password":"pw","totp":"KEY","uris":[{"uri":"https://mail.example.com"},{"uri":"https://webmail.example.com"}]}},
          {"type":2,"name":"A note"},
          {"type":1,"name":"Nopass","login":{"username":"x","uris":[{"uri":"https://x.example"}]}}
        ]}
        """
        let p = try XCTUnwrap(PasswordImport.parse(Data(json.utf8)))
        XCTAssertEqual(p.candidates.count, 1)
        XCTAssertEqual(p.candidates[0].extras.title, "Mail")
        XCTAssertEqual(p.candidates[0].extras.totp, "KEY")
        XCTAssertEqual(p.candidates[0].extras.urls, ["https://webmail.example.com"])
        XCTAssertEqual(p.problems.count, 1)
    }

    func testThePlanSortsNewFromKeptAndSameFromDifferent() throws {
        let p = try parsed("url,username,password\nhttps://a.example,ann,one\nhttps://a.example,bob,two\nhttps://b.example,cat,three\nhttps://b.example,CAT,dup\n")
        let kept = [Kept(host: "a.example", user: "ann"), Kept(host: "a.example", user: "bob")]
        let plan = PasswordImport.plan(p, kept: kept) { $0.user == "ann" ? "one" : "other" }
        XCTAssertEqual(plan.same.map(\.user), ["ann"])
        XCTAssertEqual(plan.different.map(\.user), ["bob"])
        XCTAssertEqual(plan.fresh.map(\.user), ["cat"])
        XCTAssertEqual(plan.problems.count, 1, "the second listing of cat")
    }

    func testCommitSkipsOrUpdates() throws {
        let p = try parsed("url,username,password\nhttps://a.example,ann,one\nhttps://a.example,bob,two\nhttps://b.example,cat,three\n")
        let kept = [Kept(host: "a.example", user: "ann"), Kept(host: "a.example", user: "bob")]
        let plan = PasswordImport.plan(p, kept: kept) { $0.user == "ann" ? "one" : "other" }
        var written: [String] = []
        let skip = PasswordImport.commit(plan, duplicates: .skip) { c, _ in written.append(c.user); return true }
        XCTAssertEqual(skip, .init(added: 1, updated: 0, skipped: 2, failed: 0))
        XCTAssertEqual(written, ["cat"])
        written = []
        let update = PasswordImport.commit(plan, duplicates: .update) { c, _ in written.append(c.user); return true }
        XCTAssertEqual(update, .init(added: 1, updated: 1, skipped: 1, failed: 0))
        XCTAssertEqual(written, ["cat", "bob"])
    }
}
