import CryptoKit
import Foundation
import XCTest
@testable import Search

@MainActor
final class SoftAuthenticatorTests: XCTestCase {
    private func hex(_ value: CBORValue) -> String {
        SoftAuthenticator.cbor(value).map { String(format: "%02x", $0) }.joined()
    }

    func testCBORMatchesRFC8949Examples() {
        XCTAssertEqual(hex(.uint(0)), "00")
        XCTAssertEqual(hex(.uint(10)), "0a")
        XCTAssertEqual(hex(.uint(23)), "17")
        XCTAssertEqual(hex(.uint(24)), "1818")
        XCTAssertEqual(hex(.uint(100)), "1864")
        XCTAssertEqual(hex(.uint(1000)), "1903e8")
        XCTAssertEqual(hex(.uint(1_000_000)), "1a000f4240")
        XCTAssertEqual(hex(.uint(1_000_000_000_000)), "1b000000e8d4a51000")
        XCTAssertEqual(hex(.negative(-1)), "20")
        XCTAssertEqual(hex(.negative(-10)), "29")
        XCTAssertEqual(hex(.negative(-100)), "3863")
        XCTAssertEqual(hex(.negative(-1000)), "3903e7")
        XCTAssertEqual(hex(.bytes(Data())), "40")
        XCTAssertEqual(hex(.bytes(Data([1, 2, 3, 4]))), "4401020304")
        XCTAssertEqual(hex(.text("")), "60")
        XCTAssertEqual(hex(.text("a")), "6161")
        XCTAssertEqual(hex(.text("IETF")), "6449455446")
        XCTAssertEqual(hex(.text("\u{00fc}")), "62c3bc")
        XCTAssertEqual(hex(.array([])), "80")
        XCTAssertEqual(hex(.array([.uint(1), .uint(2), .uint(3)])), "83010203")
        XCTAssertEqual(hex(.array([.uint(1), .array([.uint(2), .uint(3)]), .array([.uint(4), .uint(5)])])), "8301820203820405")
        XCTAssertEqual(hex(.map([])), "a0")
        XCTAssertEqual(hex(.map([(.uint(1), .uint(2)), (.uint(3), .uint(4))])), "a201020304")
        XCTAssertEqual(hex(.map([(.text("a"), .uint(1)), (.text("b"), .array([.uint(2), .uint(3)]))])), "a26161016162820203")
    }

    func testMapKeysComeOutInCanonicalOrder() {
        // Length first, then bytewise: "b" before "aa", whatever order given.
        XCTAssertEqual(hex(.map([(.text("aa"), .uint(1)), (.text("b"), .uint(2))])), "a2616202626161" + "01")
    }

    func testMadeCredentialRoundTripsThroughTheReader() throws {
        let rp = "example.com"
        let made = SoftAuthenticator.makeCredential(rp: rp, clientDataJSON: Data("{}".utf8), userHandle: Data([9, 8, 7]), userName: "ada", displayName: "Ada", userVerified: true, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(made.record.rp, rp)
        XCTAssertEqual(made.record.credentialID.count, 32)
        XCTAssertEqual(made.record.userHandle, Data([9, 8, 7]))
        XCTAssertEqual(made.record.created, Date(timeIntervalSince1970: 100))
        XCTAssertNil(made.record.lastUsed)

        // The attestation object opens to {"fmt":"none","attStmt":{},"authData":...} in that order.
        var opening = Data([0xA3, 0x63])
        opening.append(Data("fmt".utf8))
        opening.append(0x64)
        opening.append(Data("none".utf8))
        opening.append(0x67)
        opening.append(Data("attStmt".utf8))
        opening.append(contentsOf: [0xA0, 0x68])
        XCTAssertEqual(made.attestationObject.prefix(opening.count), opening)

        let data = try XCTUnwrap(Passkeys.authenticatorData(inAttestation: made.attestationObject))
        XCTAssertEqual(Data(data.prefix(32)), Data(SHA256.hash(data: Data(rp.utf8))))
        XCTAssertEqual(data[32], 0x45, "UP, UV and AT")
        XCTAssertEqual(Array(data[33..<37]), [0, 0, 0, 0])
        XCTAssertEqual(Array(data[37..<53]), [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(Int(data[53]) << 8 | Int(data[54]), 32)
        XCTAssertEqual(Data(data[55..<87]), made.record.credentialID)

        let found = try XCTUnwrap(Passkeys.publicKey(inAuthenticatorData: data))
        XCTAssertEqual(found.algorithm, -7)
        XCTAssertEqual(found.der, made.key.publicKey.derRepresentation)
    }

    func testFlagsFollowUserVerification() throws {
        let made = SoftAuthenticator.makeCredential(rp: "a.test", clientDataJSON: Data(), userHandle: Data(), userName: "", displayName: "", userVerified: false, now: Date())
        let data = try XCTUnwrap(Passkeys.authenticatorData(inAttestation: made.attestationObject))
        XCTAssertEqual(data[32], 0x41)
        XCTAssertEqual(SoftAuthenticator.assertion(rp: "a.test", clientDataJSON: Data(), key: made.key, userVerified: false).authenticatorData[32], 0x01)
        XCTAssertEqual(SoftAuthenticator.assertion(rp: "a.test", clientDataJSON: Data(), key: made.key, userVerified: true).authenticatorData[32], 0x05)
    }

    func testCredentialsAreDistinct() {
        func make() -> SoftAuthenticator.Made {
            SoftAuthenticator.makeCredential(rp: "a.test", clientDataJSON: Data(), userHandle: Data(), userName: "", displayName: "", userVerified: true, now: Date())
        }
        XCTAssertNotEqual(make().record.credentialID, make().record.credentialID)
    }

    func testAssertionSignatureVerifiesAgainstThePublicKey() throws {
        let key = P256.Signing.PrivateKey()
        let client = Data(#"{"type":"webauthn.get","challenge":"abc"}"#.utf8)
        let result = SoftAuthenticator.assertion(rp: "example.com", clientDataJSON: client, key: key, userVerified: true)
        XCTAssertEqual(result.authenticatorData.count, 37)
        XCTAssertEqual(result.authenticatorData[32], 0x05)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: result.signature)
        let signed = result.authenticatorData + Data(SHA256.hash(data: client))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: signed))
        XCTAssertFalse(key.publicKey.isValidSignature(signature, for: signed + Data([0])))
    }

    func testMadeHereStaysDeviceBound() {
        let key = P256.Signing.PrivateKey()
        XCTAssertEqual(SoftAuthenticator.assertion(rp: "a.test", clientDataJSON: Data(), key: key, userVerified: true).authenticatorData[32] & 0x18, 0)
        XCTAssertEqual(SoftAuthenticator.assertion(rp: "a.test", clientDataJSON: Data(), key: key, userVerified: true,
                                                   backupEligible: true).authenticatorData[32] & 0x18, 0x08)
    }

    func testAPagesNameCannotWriteIntoTheTouchIDLine() {
        // A second line, a right-to-left override and a tab are flattened.
        XCTAssertEqual(SoftPasskeys.shown("ada\n\nCairn is trying to approve a payment"), "ada Cairn is trying to approve a payment")
        XCTAssertEqual(SoftPasskeys.shown("evil\u{202E}moc.knab"), "evil moc.knab")
        XCTAssertEqual(SoftPasskeys.shown("\tada\r"), "ada")
        XCTAssertEqual(SoftPasskeys.shown("ada@example.com"), "ada@example.com")
        let long = SoftPasskeys.shown(String(repeating: "a", count: 500))
        XCTAssertEqual(long.count, 65)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testCounterIsBigEndian() {
        let data = SoftAuthenticator.authenticatorData(rp: "a.test", flags: 0x01, counter: 0x0102_0304, attested: nil)
        XCTAssertEqual(Array(data[33..<37]), [1, 2, 3, 4])
    }
}
