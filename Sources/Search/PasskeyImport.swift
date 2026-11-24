import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// Passkeys (and passwords) handed over by the Passwords app's Export to
/// Another App, through the Credential Exchange of macOS 26 and later.
///
/// How it arrives: the exporting app picks Cairn, the system launches us with
/// an NSUserActivity of type `ASCredentialExchangeActivity` whose userInfo
/// holds a one-time token under `ASCredentialImportToken`, and
/// `ASCredentialImportManager.importCredentials(token:)` gives the data. macOS
/// decides which apps it offers; that Cairn is offered at all is not ours to
/// promise (see the note on the Passkeys tab).
///
/// Nothing is kept before Touch ID. Nothing secret is logged or announced:
/// only counts and reasons.
enum PasskeyImport {
    /// Why a passkey in the export wasn't taken. Shown, so never a secret.
    enum Skip: String, CaseIterable, Error {
        /// Cairn's authenticator signs ES256 (P-256) only; an Ed25519 or RSA
        /// passkey can't be used here.
        case notES256 = "a key type Cairn can't sign with"
        /// No site, no credential id, or a user handle WebAuthn wouldn't allow.
        case incomplete = "incomplete"
    }

    /// What an export maps to, before anything is kept.
    struct Mapped {
        /// Who sent it ("Passwords"), for the Touch ID line.
        var source = ""
        var passkeys: [(record: PasskeyRecord, key: P256.Signing.PrivateKey)] = []
        var skipped: [Skip: Int] = [:]
        var logins: [PasswordImport.Candidate] = []
        /// Code secrets kept beside a password of the same item.
        var codes = 0
        /// Code secrets with no password beside them: a code is kept in a
        /// password's item here, so these have nowhere to go.
        var loneCodes = 0
        /// Items of other kinds (cards, notes alone, Wi-Fi…), not taken.
        var other = 0

        var skippedPasskeys: Int { skipped.values.reduce(0, +) }
        var isEmpty: Bool { passkeys.isEmpty && logins.isEmpty }
    }

    // MARK: - mapping (pure)

    /// Sorts the export into what Cairn can keep. Reads no keychain and shows
    /// nothing, so a test can hand it made-up data.
    @available(macOS 26.0, *)
    static func map(_ data: ASExportedCredentialData, now: Date = Date()) -> Mapped {
        var out = Mapped(source: data.exporterDisplayName)
        for account in data.accounts {
            for item in account.items {
                take(item, now: now, into: &out)
            }
        }
        return out
    }

    @available(macOS 26.0, *)
    private static func take(_ item: ASImportableItem, now: Date, into out: inout Mapped) {
        var code: String?
        var notes: String?
        var logins: [(user: String, password: String)] = []
        for credential in item.credentials {
            switch credential {
            case .passkey(let passkey):
                switch passkeyEntry(passkey, created: item.created ?? now) {
                case .success(let entry): out.passkeys.append(entry)
                case .failure(let skip): out.skipped[skip, default: 0] += 1
                }
            case .basicAuthentication(let basic):
                // An item with a passkey only often carries an empty login
                // beside it; that isn't a password to keep.
                guard let password = basic.password?.value, !password.isEmpty else { continue }
                logins.append((basic.userName?.value ?? "", password))
            case .totp(let totp):
                // The first is the one a site gave; a second is rare and
                // would have no field to go in.
                if code == nil { code = otpauth(totp) }
            case .note(let note):
                if notes == nil, !note.content.value.isEmpty { notes = note.content.value }
            default:
                out.other += 1
            }
        }
        guard !logins.isEmpty else {
            if code != nil { out.loneCodes += 1 }
            return
        }
        // The item's web addresses: the first is where it is kept, the rest
        // listed with it. An Android app's scope names a package, not a site.
        let addresses = (item.scope?.urls ?? []).map(\.absoluteString).filter { !Vault.host(of: $0).isEmpty }
        guard let first = addresses.first else {
            // Nowhere to fill it: counted with the other kinds, as a CSV
            // row without an address is a problem there.
            out.other += logins.count
            return
        }
        let host = Vault.host(of: first)
        var extras = Extras()
        extras.totp = code
        extras.notes = notes
        let more = addresses.dropFirst().filter { Vault.host(of: $0) != host }
        if !more.isEmpty { extras.urls = Array(more) }
        if code != nil { out.codes += 1 }
        for login in logins {
            out.logins.append(PasswordImport.Candidate(host: host, user: login.user, password: login.password,
                                                       clear: first.lowercased().hasPrefix("http://"), extras: extras))
        }
    }

    /// One exported passkey as a record Cairn's authenticator can sign with.
    @available(macOS 26.0, *)
    static func passkeyEntry(_ passkey: ASImportableCredential.Passkey, created: Date)
        -> Result<(record: PasskeyRecord, key: P256.Signing.PrivateKey), Skip> {
        let rp = passkey.relyingPartyIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // The rp is a domain: anything with a space, a slash or a control
        // character in it isn't one, and \u{1} would break PasskeyRecord.id.
        let bad = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "/"))
        guard !rp.isEmpty, rp.rangeOfCharacter(from: bad) == nil,
              (1...1023).contains(passkey.credentialID.count),
              // As SoftPasskeys.create takes them: WebAuthn's user handle is 1 to 64 bytes.
              (1...64).contains(passkey.userHandle.count)
        else { return .failure(.incomplete) }
        guard let key = privateKey(passkey.key) else { return .failure(.notES256) }
        let display = passkey.userDisplayName.isEmpty ? passkey.userName : passkey.userDisplayName
        let record = PasskeyRecord(rp: rp, credentialID: passkey.credentialID, userHandle: passkey.userHandle,
                                   userName: passkey.userName, displayName: display, created: created, lastUsed: nil)
        return .success((record, key))
    }

    /// The Credential Exchange Format gives a passkey's key as PKCS#8 DER;
    /// CryptoKit's DER reader takes that (and SEC1) for P-256 and refuses any
    /// other curve or algorithm, which is the ES256 check. The format writes
    /// the key as base64url text on the wire; should the Data ever hold that
    /// text rather than the decoded bytes, it is decoded first.
    static func privateKey(_ data: Data) -> P256.Signing.PrivateKey? {
        if let key = try? P256.Signing.PrivateKey(derRepresentation: data) { return key }
        guard let text = String(data: data, encoding: .ascii), let decoded = base64URL(text) else { return nil }
        return try? P256.Signing.PrivateKey(derRepresentation: decoded)
    }

    static func base64URL(_ text: String) -> Data? {
        var plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while plain.count % 4 != 0 { plain += "=" }
        return Data(base64Encoded: plain)
    }

    /// A code secret as the otpauth link Extras.totp keeps (TOTP.key reads it
    /// back). The secret goes in base-32, as setup QR codes write it.
    @available(macOS 26.0, *)
    static func otpauth(_ totp: ASImportableCredential.TOTP) -> String? {
        guard !totp.secret.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = "otpauth"
        parts.host = "totp"
        let label = [totp.issuer, totp.userName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
        parts.path = "/" + label
        var query = [URLQueryItem(name: "secret", value: base32(totp.secret))]
        if let issuer = totp.issuer, !issuer.isEmpty { query.append(URLQueryItem(name: "issuer", value: issuer)) }
        let algorithm: TOTP.Algorithm = switch totp.algorithm {
        case .sha1: .sha1
        case .sha256: .sha256
        case .sha512: .sha512
        @unknown default: .sha1
        }
        query.append(URLQueryItem(name: "algorithm", value: algorithm.rawValue))
        query.append(URLQueryItem(name: "digits", value: String(totp.digits)))
        query.append(URLQueryItem(name: "period", value: String(totp.period)))
        parts.queryItems = query
        return parts.string
    }

    /// RFC 4648 base-32, unpadded: what TOTP.base32 reads.
    static func base32(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = ""
        var buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 0x1F])
                bits -= 5
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 0x1F]) }
        return out
    }

    // MARK: - receiving

    /// Told whenever passkeys were kept from an export, so an open Passkeys
    /// tab lists them.
    static let changed = Notification.Name("PasskeyImport.changed")

    /// Whether this activity is an export handed to us; if so, it is taken
    /// from here on (the caller returns true).
    @available(macOS 26.0, *)
    @MainActor
    static func receive(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == ASCredentialExchangeActivity else { return false }
        // The docs give the token as a UUID; its string form is taken too,
        // since a userInfo crossing processes may carry either.
        let raw = activity.userInfo?[ASCredentialImportToken]
        guard let token = (raw as? UUID) ?? (raw as? String).flatMap(UUID.init(uuidString:)) else {
            NSLog("PasskeyImport: an export arrived with no token")
            Browsers.frontBrowser.announce("The export couldn't be read")
            return true
        }
        Task { @MainActor in
            do {
                let data = try await ASCredentialImportManager().importCredentials(token: token)
                bringIn(map(data))
            } catch {
                // Domain and code only: nothing of the export is in them.
                let failure = error as NSError
                NSLog("PasskeyImport: import failed (%@ %ld)", failure.domain, failure.code)
                Browsers.frontBrowser.announce("The export couldn't be brought in")
            }
        }
        return true
    }

    /// Touch ID, then everything at once: passkeys into PasskeyStore,
    /// passwords into the Vault as a passwords file would go (one already kept
    /// for the same site and name is left as it is).
    @MainActor
    static func bringIn(_ mapped: Mapped) {
        let browser = Browsers.frontBrowser
        guard !mapped.isEmpty else {
            browser.announce(mapped.skippedPasskeys > 0
                             ? "Nothing brought in: \(mapped.skippedPasskeys) passkey\(mapped.skippedPasskeys == 1 ? "" : "s") Cairn can't use"
                             : "Nothing in the export Cairn can keep")
            return
        }
        let from = mapped.source.isEmpty ? "another app" : mapped.source
        Vault.prove("bring in \(counted(mapped.passkeys.count, "passkey")) and \(counted(mapped.logins.count, "password")) from \(from)") { ok in
            guard ok else { return browser.announce("Nothing was brought in") }
            var kept = 0, refused = 0
            for entry in mapped.passkeys {
                PasskeyStore.save(entry.record, key: entry.key) ? (kept += 1) : (refused += 1)
            }
            if kept > 0 { NotificationCenter.default.post(name: changed, object: nil) }
            let logins = mapped.logins
            Task { @MainActor in
                // Off the main thread, as the Passwords page's own import is.
                let result = await Task.detached(priority: .userInitiated) {
                    let parsed = PasswordImport.Parsed(source: from, candidates: logins, problems: [])
                    // No secret is read: with "keep what I have", one already
                    // kept is left alone whatever its password.
                    let plan = PasswordImport.plan(parsed, kept: Vault.all(), secret: { _ in nil })
                    return PasswordImport.commit(plan, duplicates: .skip) { candidate, _ in
                        Vault.save(host: candidate.host, user: candidate.user, password: candidate.password,
                                   clear: candidate.clear, extras: candidate.extras)
                    }
                }.value
                if result.added > 0 { browser.relist() }
                browser.announce(summary(mapped, kept: kept, refused: refused, passwords: result))
            }
        }
    }

    private static func counted(_ n: Int, _ one: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(one)s" }

    /// What happened, in one line: counts and reasons, never a name or a site.
    static func summary(_ mapped: Mapped, kept: Int, refused: Int, passwords: PasswordImport.Result) -> String {
        var parts = ["Brought in \(counted(kept, "passkey"))"]
        if passwords.added > 0 || !mapped.logins.isEmpty { parts.append(counted(passwords.added, "password")) }
        if mapped.codes > 0 { parts.append("\(mapped.codes) with codes") }
        for skip in Skip.allCases {
            if let n = mapped.skipped[skip], n > 0 { parts.append("\(counted(n, "passkey")) skipped (\(skip.rawValue))") }
        }
        if passwords.skipped > 0 { parts.append("\(passwords.skipped) already kept") }
        if refused + passwords.failed > 0 { parts.append("\(refused + passwords.failed) the keychain refused") }
        if mapped.loneCodes > 0 { parts.append("\(mapped.loneCodes) codes with no password left out") }
        return parts.joined(separator: " · ")
    }
}
