import Foundation

// Passkey Inspector, for a local site you turned the Dev Bridge on for: what
// the last passkey ceremony on that origin said, so a developer can see why
// a sign-in did or didn't take. READ-ONLY metadata, in memory, and nothing
// else: the relying party ID, whether the user was present and verified, the
// backup flags, whether a credential came with it, the signature counter,
// and the credential ID (a public name for the credential, as the page
// itself received it). Never a key, a signature, a user handle or name, or an
// attestation. It is kept only for an origin the bridge is on for, shown only
// while it is, and forgotten when the bridge is turned off.
//
// There are no simulation toggles. The ceremonies the Mac's passkeys answer
// are the system's, and the browser's own authenticator (SoftAuthenticator) is
// for imported passkeys, not for localhost: switching either's behaviour
// could not be kept to the localhost relying party, so this only looks.

struct PasskeyCeremony: Equatable {
    let kind: String
    let rp: String
    let userPresent: Bool
    let userVerified: Bool
    let backupEligible: Bool
    let backedUp: Bool
    /// A credential was made and came with it.
    let attested: Bool
    let counter: UInt32
    /// base64url, as the page saw it.
    let credentialID: String
    let at: Date
}

@MainActor
final class PasskeyInspector: ObservableObject {
    static let shared = PasskeyInspector()

    @Published private var ceremonies: [DevOrigin: PasskeyCeremony] = [:]

    /// A ceremony's metadata from its authenticator data (RP hash, flags,
    /// counter), or nil when that is too short to be one.
    static func ceremony(kind: String, rp: String, credentialID: Data, authenticatorData data: Data, now: Date = Date()) -> PasskeyCeremony? {
        let bytes = [UInt8](data)
        guard bytes.count >= 37 else { return nil }
        let flags = bytes[32]
        let counter = bytes[33...36].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let id = credentialID.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return PasskeyCeremony(kind: kind, rp: rp, userPresent: flags & 0x01 != 0, userVerified: flags & 0x04 != 0,
                               backupEligible: flags & 0x08 != 0, backedUp: flags & 0x10 != 0, attested: flags & 0x40 != 0,
                               counter: counter, credentialID: id, at: now)
    }

    /// Kept only while the bridge is on for `origin`.
    func note(_ ceremony: PasskeyCeremony, for origin: DevOrigin, granted: Bool) {
        guard granted else { return }
        ceremonies[origin] = ceremony
    }

    func last(for origin: DevOrigin, granted: Bool) -> PasskeyCeremony? {
        granted ? ceremonies[origin] : nil
    }

    /// Whatever isn't for a granted origin any more is forgotten.
    func prune(granted: Set<DevOrigin>) {
        ceremonies = ceremonies.filter { granted.contains($0.key) }
    }
}
