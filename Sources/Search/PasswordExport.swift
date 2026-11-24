import Foundation
import CryptoKit
import CommonCrypto

/// Passwords taken out: a plain CSV any other manager reads, or an encrypted
/// file only the passphrase opens. Nothing is written here; the page asks for
/// the Mac's proof, reads the items, and hands them in.
enum PasswordExport {
    // MARK: - CSV

    /// Chrome's columns, with the code key on the end so a code isn't lost on
    /// the way (the importer reads it back; Chrome ignores it).
    nonisolated static let header = ["name", "url", "username", "password", "note", "otpauth"]

    nonisolated static func csv(_ items: [Item]) -> String {
        var lines = [header.joined(separator: ",")]
        for item in items.sorted(by: { $0.host == $1.host ? $0.user < $1.user : $0.host < $1.host }) {
            let title = (item.extras.title ?? "").isEmpty ? item.host : (item.extras.title ?? "")
            let address = (item.clear ? "http://" : "https://") + item.host
            let cells = [title, address, item.user, item.password, item.extras.notes ?? "", item.extras.totp ?? ""]
            lines.append(cells.map(quote).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// A cell quoted only when it has to be. Nothing is prefixed against
    /// spreadsheet formulas: that would change the password.
    private nonisolated static func quote(_ cell: String) -> String {
        guard cell.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return cell }
        return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - the encrypted file

    /// What the file says it is, and (as authenticated data) is bound to the
    /// sealed box, so a file with another label doesn't open.
    private nonisolated static let label = "cairnvault"
    nonisolated static let ext = "cairnvault"
    nonisolated static let rounds = 600_000

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var kdf: String
        var rounds: Int
        var salt: String
        var box: String
    }

    /// One login as the file holds it.
    private struct Entry: Codable {
        var host: String
        var user: String
        var password: String
        var clear: Bool
        var title: String?
        var notes: String?
        var totp: String?
        var urls: [String]?
        var changed: Double?
    }

    private struct Inside: Codable {
        var items: [Entry]
    }

    enum Failure: Error, Equatable {
        /// Not one of ours, or damaged past reading.
        case notAVault
        /// Made by a newer build than this one.
        case tooNew
        /// The passphrase doesn't open it (or the file was changed).
        case wrongPassphrase
    }

    /// A passphrase worth keeping a backup under.
    nonisolated static let shortest = 8

    /// Whether this is one of our backup files, without opening it.
    nonisolated static func isVault(_ data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return false }
        return envelope.format == label
    }

    /// The key a passphrase and a salt make: PBKDF2 with HMAC-SHA256, from the
    /// system's own CommonCrypto.
    private nonisolated static func key(_ passphrase: String, salt: Data, rounds: Int) -> SymmetricKey? {
        var derived = [UInt8](repeating: 0, count: 32)
        let secret = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        let status = secret.withUnsafeBufferPointer { secretBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     secretBytes.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) },
                                     secret.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                     &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { return nil }
        return SymmetricKey(data: derived)
    }

    /// The items, sealed under the passphrase. Nil only if the cipher fails
    /// or the passphrase is too short.
    nonisolated static func seal(_ items: [Item], passphrase: String, rounds: Int = PasswordExport.rounds) -> Data? {
        guard passphrase.count >= shortest else { return nil }
        let inside = Inside(items: items.map {
            Entry(host: $0.host, user: $0.user, password: $0.password, clear: $0.clear,
                  title: $0.extras.title, notes: $0.extras.notes, totp: $0.extras.totp, urls: $0.extras.urls,
                  changed: $0.extras.changed?.timeIntervalSince1970)
        })
        // The system's own secure generator.
        var random = SystemRandomNumberGenerator()
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &random) })
        guard let plain = try? JSONEncoder().encode(inside),
              let key = key(passphrase, salt: salt, rounds: rounds),
              let box = try? AES.GCM.seal(plain, using: key, authenticating: Data(label.utf8)),
              let combined = box.combined
        else { return nil }
        let envelope = Envelope(format: label, version: 1, kdf: "pbkdf2-sha256", rounds: rounds,
                                salt: salt.base64EncodedString(), box: combined.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(envelope)
    }

    /// What a backup file holds, in the shape the importer already sorts and
    /// previews. Nothing is written by this.
    nonisolated static func open(_ data: Data, passphrase: String) -> Result<PasswordImport.Parsed, Failure> {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.format == label else {
            return .failure(.notAVault)
        }
        guard envelope.version <= 1 else { return .failure(.tooNew) }
        // A file can't ask for hours of work, or for none.
        guard envelope.kdf == "pbkdf2-sha256", (1_000...5_000_000).contains(envelope.rounds),
              let salt = Data(base64Encoded: envelope.salt), let combined = Data(base64Encoded: envelope.box)
        else { return .failure(.notAVault) }
        guard let key = key(passphrase, salt: salt, rounds: envelope.rounds),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key, authenticating: Data(label.utf8))
        else { return .failure(.wrongPassphrase) }
        guard let inside = try? JSONDecoder().decode(Inside.self, from: plain) else { return .failure(.notAVault) }

        var problems: [PasswordImport.Problem] = []
        var candidates: [PasswordImport.Candidate] = []
        for (index, entry) in inside.items.enumerated() {
            guard !entry.host.isEmpty, !entry.password.isEmpty else {
                problems.append(PasswordImport.Problem(row: index + 1, why: entry.host.isEmpty ? "No address" : "No password"))
                continue
            }
            var extras = Extras()
            extras.title = entry.title
            extras.notes = entry.notes
            extras.totp = entry.totp
            extras.urls = entry.urls
            extras.changed = entry.changed.map(Date.init(timeIntervalSince1970:))
            candidates.append(PasswordImport.Candidate(host: entry.host, user: entry.user, password: entry.password,
                                                       clear: entry.clear, extras: extras))
        }
        return .success(PasswordImport.Parsed(source: "a \(Brand.name) backup", candidates: candidates, problems: problems))
    }
}
