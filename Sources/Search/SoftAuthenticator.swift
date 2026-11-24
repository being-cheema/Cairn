import CryptoKit
import Foundation

/// The few CBOR shapes a WebAuthn attestation needs (RFC 8949). A map keeps
/// its pairs in the order given; `cbor(_:)` sorts them into canonical order.
indirect enum CBORValue {
    case uint(UInt64)
    /// A negative integer as itself (-7 is `.negative(-7)`), below zero.
    case negative(Int64)
    case bytes(Data)
    case text(String)
    case array([CBORValue])
    case map([(CBORValue, CBORValue)])
}

/// A WebAuthn level 2 authenticator in software, for a build that can't use
/// Apple's passkeys (see SPEC-passkeys.md). Pure: no keychain and no UI, so
/// the caller keeps the key and decides when Touch ID has been proven.
enum SoftAuthenticator {
    struct Made {
        let record: PasskeyRecord
        let key: P256.Signing.PrivateKey
        let attestationObject: Data
    }

    /// A new ES256 credential, attested with `none`. The client data isn't
    /// part of a `none` attestation; the page's reply carries it as it is.
    static func makeCredential(rp: String, clientDataJSON: Data, userHandle: Data, userName: String, displayName: String, userVerified: Bool, now: Date) -> Made {
        var generator = SystemRandomNumberGenerator()
        let credentialID = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let key = P256.Signing.PrivateKey()

        // The public point is 0x04 || x || y; COSE wants x and y apart.
        let point = key.publicKey.x963Representation
        let x = point.dropFirst().prefix(32)
        let y = point.dropFirst(33).prefix(32)
        let coseKey = cbor(.map([
            (.uint(1), .uint(2)),            // kty: EC2
            (.uint(3), .negative(-7)),       // alg: ES256
            (.negative(-1), .uint(1)),       // crv: P-256
            (.negative(-2), .bytes(Data(x))),
            (.negative(-3), .bytes(Data(y))),
        ]))

        var flags: UInt8 = 0x01 | 0x40
        if userVerified { flags |= 0x04 }
        let authData = authenticatorData(rp: rp, flags: flags, counter: 0, attested: (credentialID, coseKey))
        let attestation = cbor(.map([
            (.text("fmt"), .text("none")),
            (.text("attStmt"), .map([])),
            (.text("authData"), .bytes(authData)),
        ]))
        let record = PasskeyRecord(rp: rp, credentialID: credentialID, userHandle: userHandle, userName: userName, displayName: displayName, created: now, lastUsed: nil)
        return Made(record: record, key: key, attestationObject: attestation)
    }

    /// Signs a sign-in: the authenticator data, then the signature over it
    /// and the hash of the client data, in the DER form WebAuthn expects.
    static func assertion(rp: String, clientDataJSON: Data, key: P256.Signing.PrivateKey, userVerified: Bool) -> (authenticatorData: Data, signature: Data) {
        let data = authenticatorData(rp: rp, flags: userVerified ? 0x05 : 0x01, counter: 0, attested: nil)
        let signed = data + Data(SHA256.hash(data: clientDataJSON))
        // signature(for:) hashes its input with SHA-256, as ES256 means.
        let signature = (try? key.signature(for: signed).derRepresentation) ?? Data()
        return (data, signature)
    }

    /// The relying party's hash, the flags, the 4-byte big-endian counter,
    /// and, on create, the credential: a zero AAGUID (no model to name), the
    /// ID with its 2-byte length, and the COSE public key.
    static func authenticatorData(rp: String, flags: UInt8, counter: UInt32, attested: (credentialID: Data, coseKey: Data)?) -> Data {
        var out = Data(SHA256.hash(data: Data(rp.utf8)))
        out.append(flags)
        out.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: counter >> UInt32(24 - 8 * $0)) })
        if let attested {
            out.append(Data(count: 16))
            let length = UInt16(truncatingIfNeeded: attested.credentialID.count)
            out.append(UInt8(length >> 8))
            out.append(UInt8(length & 0xFF))
            out.append(attested.credentialID)
            out.append(attested.coseKey)
        }
        return out
    }

    /// Shortest-form CBOR; map keys sorted by encoded length, then bytewise
    /// (the CTAP2 canonical order), so the same map always encodes the same.
    static func cbor(_ value: CBORValue) -> Data {
        switch value {
        case .uint(let n):
            return head(0, n)
        case .negative(let n):
            return head(1, UInt64(-(n + 1)))
        case .bytes(let data):
            return head(2, UInt64(data.count)) + data
        case .text(let string):
            let utf8 = Data(string.utf8)
            return head(3, UInt64(utf8.count)) + utf8
        case .array(let items):
            return items.reduce(head(4, UInt64(items.count))) { $0 + cbor($1) }
        case .map(let pairs):
            let encoded = pairs.map { (key: cbor($0.0), value: cbor($0.1)) }.sorted { a, b in
                a.key.count != b.key.count ? a.key.count < b.key.count : a.key.lexicographicallyPrecedes(b.key)
            }
            return encoded.reduce(head(5, UInt64(encoded.count))) { $0 + $1.key + $1.value }
        }
    }

    /// The initial byte (major type) and the argument in its shortest form.
    private static func head(_ major: UInt8, _ n: UInt64) -> Data {
        let m = major << 5
        func be(_ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: n >> UInt64(8 * (count - 1 - $0))) } }
        switch n {
        case 0..<24: return Data([m | UInt8(n)])
        case 24..<0x100: return Data([m | 24] + be(1))
        case 0x100..<0x1_0000: return Data([m | 25] + be(2))
        case 0x1_0000..<0x1_0000_0000: return Data([m | 26] + be(4))
        default: return Data([m | 27] + be(8))
        }
    }
}
