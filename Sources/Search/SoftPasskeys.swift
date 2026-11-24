import AppKit
import AuthenticationServices

/// Passkeys Cairn keeps itself (SPEC-passkeys.md), for a build the Mac's own
/// passkey sign-in can't be reached from: that needs an entitlement only the
/// paid Apple program grants. A page's request is the same one `Passkeys`
/// checks and carries; this answers it from the keychain instead of the Mac's
/// sheet, and Touch ID is the proof that you are you.
///
/// What it does not do: sign in with a passkey kept in iCloud, or any made
/// elsewhere. Those can't be moved here. A site is told, as by any browser
/// with no passkey for it, that nothing is there, and goes on to the password.
@MainActor
enum SoftPasskeys {
    /// On whenever the Mac's own can't be had. A build with the entitlement
    /// keeps using the Mac's.
    static var on: Bool { !Preferences.entitledToPasskeys }

    /// The client data the signature covers, written here: the origin in it is
    /// the one WebKit reports for the frame (see Passkeys.perform), never one
    /// the page states.
    static func clientDataJSON(type: String, _ data: ASPublicKeyCredentialClientData) -> Data {
        var fields = [
            "\"type\":\"webauthn.\(type)\"",
            "\"challenge\":\"\(Passkeys.text(data.challenge))\"",
            "\"origin\":\"\(escaped(data.origin))\"",
            "\"crossOrigin\":\(data.crossOrigin == .crossOrigin ? "true" : "false")",
        ]
        if let top = data.topOrigin { fields.append("\"topOrigin\":\"\(escaped(top))\"") }
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func fail(_ answer: ([String: Any]) -> Void, _ name: String, _ message: String) {
        answer(["error": name, "message": message])
    }

    // MARK: - making one

    /// A site asks for a passkey: made and kept here after Touch ID.
    static func create(_ body: [String: Any], rp: String, clientData: ASPublicKeyCredentialClientData,
                       answer: @escaping ([String: Any]) -> Void) {
        guard let user = body["user"] as? [String: Any],
              let userID = Passkeys.data(user["id"]), (1...64).contains(userID.count),
              let name = user["name"] as? String
        else { return fail(answer, "TypeError", "The request names no user, or one too long.") }
        let display = (user["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        // No list means ES256 or RS256, as the standard has it; only the first is made here.
        let algorithms = (body["algorithms"] as? [Int]).flatMap { $0.isEmpty ? nil : $0 } ?? [-7, -257]
        guard algorithms.contains(-7) else {
            return fail(answer, "NotSupportedError", "Cairn's passkeys use ES256, which this site doesn't take.")
        }
        // A security key is what the site wants; this isn't one.
        guard body["authenticatorAttachment"] as? String != "cross-platform" else {
            return fail(answer, "NotAllowedError", "The operation either timed out or was not allowed.")
        }
        // One already kept for this site and listed as excluded: the site says
        // so by this error, as it does for any authenticator.
        let excluded = Passkeys.descriptors(body["excludeCredentials"]).map(\.id)
        if !excluded.isEmpty, !PasskeyStore.records(rp: rp, allowed: excluded).isEmpty {
            return fail(answer, "InvalidStateError", "A passkey for this account is already kept here.")
        }
        Vault.prove("save a passkey for \(rp) as \(name)") { ok in
            guard ok else { return fail(answer, "NotAllowedError", "The operation either timed out or was not allowed.") }
            let json = clientDataJSON(type: "create", clientData)
            let made = SoftAuthenticator.makeCredential(rp: rp, clientDataJSON: json, userHandle: userID, userName: name,
                                                        displayName: display, userVerified: true, now: Date())
            guard PasskeyStore.save(made.record, key: made.key) else {
                return fail(answer, "UnknownError", "The passkey couldn't be kept in the keychain.")
            }
            answer(Passkeys.registrationReply(id: made.record.credentialID, clientData: json, attestation: made.attestationObject,
                                              transports: ["internal"], attachment: "platform"))
        }
    }

    // MARK: - signing in

    /// The passkeys kept for a request: the ones it names, or every one for
    /// the site.
    static func kept(for body: [String: Any], rp: String) -> [PasskeyRecord] {
        PasskeyStore.records(rp: rp, allowed: Passkeys.descriptors(body["allowCredentials"]).map(\.id))
    }

    /// A site asks for a passkey. `chosen` is the one picked under a field;
    /// otherwise, with several for the site, you pick. Then Touch ID, then it
    /// signs.
    static func get(_ body: [String: Any], rp: String, clientData: ASPublicKeyCredentialClientData, chosen: Data? = nil,
                    answer: @escaping ([String: Any]) -> Void) {
        let matches = chosen.map { id in kept(for: body, rp: rp).filter { $0.credentialID == id } } ?? kept(for: body, rp: rp)
        guard let record = pick(from: matches, rp: rp) else {
            return fail(answer, "NotAllowedError", "The operation either timed out or was not allowed.")
        }
        Vault.prove("sign in to \(rp) as \(record.userName)") { ok in
            guard ok, let key = PasskeyStore.key(for: record) else {
                return fail(answer, "NotAllowedError", "The operation either timed out or was not allowed.")
            }
            let json = clientDataJSON(type: "get", clientData)
            let signed = SoftAuthenticator.assertion(rp: rp, clientDataJSON: json, key: key, userVerified: true)
            PasskeyStore.touch(record)
            answer(Passkeys.assertionReply(id: record.credentialID, clientData: json, authenticatorData: signed.authenticatorData,
                                           signature: signed.signature, user: record.userHandle, attachment: "platform"))
        }
    }

    /// The only one, or the one chosen from a list; nil when there is none or
    /// the list is cancelled. A test run takes the first: no sheet.
    private static func pick(from records: [PasskeyRecord], rp: String) -> PasskeyRecord? {
        guard records.count > 1, !Store.testing else { return records.first }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(rp) with a passkey"
        alert.informativeText = "Which account?"
        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for record in records { menu.addItem(withTitle: record.userName.isEmpty ? record.displayName : record.userName) }
        alert.accessoryView = menu
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, records.indices.contains(menu.indexOfSelectedItem) else { return nil }
        return records[menu.indexOfSelectedItem]
    }

    // MARK: - offered under a field

    /// What a page waiting under its sign-in field is offered: the passkeys
    /// kept for the site. Asking reads no secret.
    static func offered(for body: [String: Any], rp: String) -> [Passkeys.Offered] {
        kept(for: body, rp: rp).prefix(8).map {
            Passkeys.Offered(id: $0.credentialID, name: String(($0.userName.isEmpty ? $0.displayName : $0.userName).prefix(200)),
                             provider: Brand.name)
        }
    }
}
