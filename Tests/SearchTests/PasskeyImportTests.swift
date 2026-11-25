import AuthenticationServices
import CryptoKit
import XCTest
@testable import Search

/// The mapping of a Credential Exchange export (PasskeyImport.map): pure, no
/// keychain, no Touch ID. Keys are written out byte by byte as PKCS#8 DER, the
/// form the Credential Exchange Format gives a passkey's key in.
final class PasskeyImportTests: XCTestCase {
    /// A P-256 private scalar: 1…32, well below the curve order.
    private let scalar = Data(1...32)

    /// PKCS#8 PrivateKeyInfo { version 0, { id-ecPublicKey, prime256v1 },
    /// OCTET STRING { ECPrivateKey { version 1, OCTET STRING scalar } } },
    /// with no public key in it, as an exporter may leave it out.
    private var p256PKCS8: Data {
        var der: [UInt8] = [0x30, 0x41, 0x02, 0x01, 0x00,
                            0x30, 0x13,
                            0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                            0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
                            0x04, 0x27, 0x30, 0x25, 0x02, 0x01, 0x01, 0x04, 0x20]
        der += scalar
        return Data(der)
    }

    /// An Ed25519 key in PKCS#8: a passkey Cairn's authenticator can't sign with.
    private var ed25519PKCS8: Data {
        Data([0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20] + Array(scalar))
    }

    private let made = Date(timeIntervalSince1970: 1_700_000_000)

    @available(macOS 26.0, *)
    private func passkey(rp: String = "example.com", handle: Data = Data([7, 7, 7]), key: Data) -> ASImportableCredential {
        .passkey(.init(credentialID: Data([0xC0, 0xFF, 0xEE]), relyingPartyIdentifier: rp, userName: "ada@example.com",
                       userDisplayName: "Ada", userHandle: handle, key: key))
    }

    @available(macOS 26.0, *)
    private func field(_ value: String) -> ASImportableEditableField {
        ASImportableEditableField(id: nil, fieldType: .string, value: value)
    }

    @available(macOS 26.0, *)
    private func item(_ credentials: [ASImportableCredential], urls: [String] = []) -> ASImportableItem {
        ASImportableItem(id: Data([1]), created: made, lastModified: made, title: "Example", subtitle: nil, favorite: false,
                         scope: ASImportableCredentialScope(urls: urls.compactMap(URL.init(string:))),
                         credentials: credentials, tags: [])
    }

    @available(macOS 26.0, *)
    private func export(_ items: [ASImportableItem]) -> ASExportedCredentialData {
        ASExportedCredentialData(accounts: [ASImportableAccount(id: Data([9]), userName: "", email: "", collections: [], items: items)],
                                 formatVersion: .v1, exporterRelyingPartyIdentifier: "apple.com",
                                 exporterDisplayName: "Passwords", timestamp: made)
    }

    func testES256PasskeyMapsWithItsKey() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Credential Exchange is macOS 26 and later") }
        let mapped = PasskeyImport.map(export([item([passkey(rp: " Example.COM ", key: p256PKCS8)])]))
        XCTAssertEqual(mapped.source, "Passwords")
        XCTAssertEqual(mapped.passkeys.count, 1)
        XCTAssertEqual(mapped.skippedPasskeys, 0)
        let entry = try XCTUnwrap(mapped.passkeys.first)
        XCTAssertEqual(entry.record.rp, "example.com")
        XCTAssertEqual(entry.record.credentialID, Data([0xC0, 0xFF, 0xEE]))
        XCTAssertEqual(entry.record.userHandle, Data([7, 7, 7]))
        XCTAssertEqual(entry.record.userName, "ada@example.com")
        XCTAssertEqual(entry.record.displayName, "Ada")
        XCTAssertEqual(entry.record.created, made)
        XCTAssertNil(entry.record.lastUsed)
        XCTAssertEqual(entry.key.rawRepresentation, scalar)
        // And it signs as Cairn's own do: the signature checks out.
        let message = Data("signed".utf8)
        let signature = try entry.key.signature(for: message)
        XCTAssertTrue(entry.key.publicKey.isValidSignature(signature, for: message))
    }

    func testABroughtInPasskeyKeepsItsBackupEligibility() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Credential Exchange is macOS 26 and later") }
        let entry = try XCTUnwrap(PasskeyImport.map(export([item([passkey(key: p256PKCS8)])])).passkeys.first)
        // Registered synced in the Passwords app (BE = 1): a sign-in from here
        // must say BE = 1 too, or a site checking it refuses.
        XCTAssertTrue(entry.record.backupEligible)
        let signed = SoftAuthenticator.assertion(rp: entry.record.rp, clientDataJSON: Data(), key: entry.key, userVerified: true,
                                                 backupEligible: entry.record.backupEligible)
        XCTAssertEqual(signed.authenticatorData[32], 0x0D, "UP, UV and BE; BS clear")
    }

    func testKeyGivenAsBase64URLTextIsReadToo() throws {
        let text = p256PKCS8.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(PasskeyImport.privateKey(Data(text.utf8))?.rawRepresentation, scalar)
        XCTAssertNil(PasskeyImport.privateKey(Data("not a key".utf8)))
    }

    func testOtherKindsAreCountedAndSkipped() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Credential Exchange is macOS 26 and later") }
        let mapped = PasskeyImport.map(export([
            item([passkey(key: ed25519PKCS8)]),
            item([passkey(rp: "", key: p256PKCS8)]),
            item([passkey(handle: Data(repeating: 1, count: 65), key: p256PKCS8)]),
            item([passkey(rp: "a b.com", key: p256PKCS8)]),
            item([.note(.init(content: field("just a note")))]),
        ]))
        XCTAssertTrue(mapped.passkeys.isEmpty)
        XCTAssertEqual(mapped.skipped[.notES256], 1)
        XCTAssertEqual(mapped.skipped[.incomplete], 3)
        XCTAssertTrue(mapped.isEmpty)
        // A note alone is neither a password nor a passkey: nothing to keep,
        // and not counted as another kind either (it rides along with a login).
        XCTAssertEqual(mapped.other, 0)
    }

    func testPasswordWithCodeBecomesACandidate() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Credential Exchange is macOS 26 and later") }
        let secret = Data("12345678901234567890".utf8)
        let totp = ASImportableCredential.TOTP(secret: secret, period: 30, digits: 6, userName: "ada", algorithm: .sha1, issuer: "Example")
        let mapped = PasskeyImport.map(export([
            item([.basicAuthentication(.init(userName: field("ada"), password: field("hunter2"))), .totp(totp),
                  passkey(key: p256PKCS8)],
                 urls: ["https://www.example.com/login", "https://accounts.example.org"]),
            // A code with no password beside it has nowhere to go here.
            item([.totp(totp)]),
            // A login with no web address can't be filled anywhere.
            item([.basicAuthentication(.init(userName: field("bo"), password: field("pw")))]),
        ]))
        XCTAssertEqual(mapped.passkeys.count, 1)
        XCTAssertEqual(mapped.logins.count, 1)
        XCTAssertEqual(mapped.codes, 1)
        XCTAssertEqual(mapped.loneCodes, 1)
        XCTAssertEqual(mapped.other, 1)
        let login = try XCTUnwrap(mapped.logins.first)
        XCTAssertEqual(login.host, "example.com")
        XCTAssertEqual(login.user, "ada")
        XCTAssertEqual(login.password, "hunter2")
        XCTAssertFalse(login.clear)
        XCTAssertEqual(login.extras.urls, ["https://accounts.example.org"])
        // The code link reads back as the same key, and gives RFC 6238's code.
        let key = try XCTUnwrap(login.extras.totp.flatMap(TOTP.key(from:)))
        XCTAssertEqual(key.secret, secret)
        XCTAssertEqual(key.digits, 6)
        XCTAssertEqual(key.period, 30)
    }

    func testBase32MatchesRFC4648() {
        XCTAssertEqual(PasskeyImport.base32(Data("foobar".utf8)), "MZXW6YTBOI")
        XCTAssertEqual(PasskeyImport.base32(Data("f".utf8)), "MY")
        XCTAssertEqual(TOTP.base32(PasskeyImport.base32(Data(0...200))), Data(0...200))
    }

    func testSummaryHoldsCountsOnly() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Credential Exchange is macOS 26 and later") }
        let mapped = PasskeyImport.map(export([
            item([passkey(key: p256PKCS8)]),
            item([passkey(key: ed25519PKCS8)]),
            item([.basicAuthentication(.init(userName: field("ada"), password: field("hunter2")))], urls: ["https://example.com"]),
        ]))
        let line = PasskeyImport.summary(mapped, kept: 1, refused: 0, passwords: PasswordImport.Result(added: 1))
        XCTAssertEqual(line, "Brought in 1 passkey · 1 password · 1 passkey skipped (a key type Cairn can't sign with)")
        for secret in ["ada", "hunter2", "example.com"] { XCTAssertFalse(line.contains(secret)) }
    }
}
