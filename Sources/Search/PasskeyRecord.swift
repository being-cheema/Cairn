import Foundation

/// A passkey Cairn keeps itself (see SPEC-passkeys.md): what a list needs to
/// show, and what a sign-in needs to find it. The private key is never here;
/// it stays in the keychain item (PasskeyStore) and is read only to sign.
struct PasskeyRecord: Identifiable, Equatable {
    /// The relying party id: the site's domain the passkey is for.
    var rp: String
    var credentialID: Data
    var userHandle: Data
    var userName: String
    var displayName: String
    var created: Date
    var lastUsed: Date?

    var id: String { rp + "\u{1}" + credentialID.base64EncodedString() }
}
