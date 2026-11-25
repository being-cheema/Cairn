import XCTest
@testable import Search

/// RFC 6238's own test vectors (Appendix B), eight digits.
final class TOTPTests: XCTestCase {
    private func eight(_ secret: String, _ algorithm: TOTP.Algorithm, _ time: TimeInterval) -> String {
        TOTP.code(for: TOTP.Key(secret: Data(secret.utf8), digits: 8, period: 30, algorithm: algorithm), at: Date(timeIntervalSince1970: time))
    }

    func testRFC6238Vectors() {
        let s1 = "12345678901234567890"
        let s256 = "12345678901234567890123456789012"
        let s512 = "1234567890123456789012345678901234567890123456789012345678901234"
        XCTAssertEqual(eight(s1, .sha1, 59), "94287082")
        XCTAssertEqual(eight(s1, .sha1, 1_111_111_109), "07081804")
        XCTAssertEqual(eight(s256, .sha256, 59), "46119246")
        XCTAssertEqual(eight(s512, .sha512, 59), "90693936")
    }

    func testSixDigitsKeepTheirLeadingZeros() {
        let key = TOTP.Key(secret: Data("12345678901234567890".utf8))
        XCTAssertEqual(TOTP.code(for: key, at: Date(timeIntervalSince1970: 59)), "287082")
        XCTAssertEqual(TOTP.code(for: key, at: Date(timeIntervalSince1970: 1_111_111_109)).count, 6)
    }

    func testBase32AndTheLink() throws {
        XCTAssertEqual(TOTP.base32("GEZDGNBVGY3TQOJQ"), Data("1234567890".utf8))
        XCTAssertEqual(TOTP.base32("gezd gnbv-gy3t qojq"), Data("1234567890".utf8))
        XCTAssertNil(TOTP.base32("not base 32!"))
        let key = try XCTUnwrap(TOTP.key(from: "otpauth://totp/GitHub:ann?secret=GEZDGNBVGY3TQOJQ&issuer=GitHub&digits=8&period=60&algorithm=SHA256"))
        XCTAssertEqual(key, TOTP.Key(secret: Data("1234567890".utf8), digits: 8, period: 60, algorithm: .sha256))
        XCTAssertNotNil(TOTP.key(from: "GEZDGNBVGY3TQOJQ"))
        XCTAssertNil(TOTP.key(from: "otpauth://hotp/x?secret=GEZDGNBVGY3TQOJQ"))
        XCTAssertNil(TOTP.key(from: ""))
    }

    func testSecondsLeftAndSpacing() {
        let key = TOTP.Key(secret: Data("x".utf8))
        XCTAssertEqual(TOTP.secondsLeft(key, at: Date(timeIntervalSince1970: 60)), 30)
        XCTAssertEqual(TOTP.secondsLeft(key, at: Date(timeIntervalSince1970: 89)), 1)
        XCTAssertEqual(TOTP.spaced("123456"), "123 456")
    }
}

final class TOTPRefusalTests: XCTestCase {
    /// Better no code than one with the wrong length or period.
    func testASettingItCantHonourRefusesTheKey() {
        XCTAssertNil(TOTP.key(from: "otpauth://totp/x?secret=GEZDGNBVGY3TQOJQ&digits=9"))
        XCTAssertNil(TOTP.key(from: "otpauth://totp/x?secret=GEZDGNBVGY3TQOJQ&period=300"))
        XCTAssertNil(TOTP.key(from: "otpauth://totp/x?secret=GEZDGNBVGY3TQOJQ&algorithm=MD5"))
        XCTAssertNotNil(TOTP.key(from: "otpauth://totp/x?secret=GEZDGNBVGY3TQOJQ&digits=8&period=60&algorithm=SHA256"))
    }
}
