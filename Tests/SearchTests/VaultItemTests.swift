import XCTest
@testable import Search

/// What a kept item's keychain value holds: the password alone, as ever, or
/// the password with notes and a code secret behind a mark.
final class VaultItemTests: XCTestCase {
    func testAPlainPasswordIsItsOwnValue() {
        XCTAssertEqual(Vault.encode("hunter2", Extras()), "hunter2")
        let (password, extras) = Vault.decode("hunter2")
        XCTAssertEqual(password, "hunter2")
        XCTAssertTrue(extras.isEmpty)
    }

    func testExtrasRoundTrip() {
        let extras = Extras(title: "Mail", notes: "line one\nline two", totp: "otpauth://totp/x?secret=ABC", urls: ["https://a.example"],
                            changed: Date(timeIntervalSince1970: 1_700_000_000))
        let value = Vault.encode("p\u{e4}ss \"quoted\" {braces}", extras)
        XCTAssertTrue(value.hasPrefix(Vault.valueMark))
        let back = Vault.decode(value)
        XCTAssertEqual(back.password, "p\u{e4}ss \"quoted\" {braces}")
        XCTAssertEqual(back.extras, extras)
    }

    func testAPasswordThatLooksLikeJSONIsStillAPassword() {
        let looksLike = "{\"p\":\"x\",\"x\":{}}"
        XCTAssertEqual(Vault.decode(looksLike).password, looksLike)
    }

    func testADamagedItemIsKeptWholeNotEmptied() {
        let damaged = Vault.valueMark + "{not json"
        XCTAssertEqual(Vault.decode(damaged).password, damaged)
    }
}
