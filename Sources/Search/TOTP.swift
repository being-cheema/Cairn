import CryptoKit
import Foundation

/// Verification codes, made here: RFC 6238 over the secret an account's setup
/// QR code holds. Nothing is sent anywhere; the secret lives in the item's
/// keychain value (Extras.totp) and is read only for the one page, tab or
/// line that shows or fills its code.
enum TOTP {
    enum Algorithm: String { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    struct Key: Equatable {
        var secret: Data
        var digits = 6
        var period = 30
        var algorithm = Algorithm.sha1
    }

    /// A setup key as a site gives it: an `otpauth://totp/…?secret=…` link, or
    /// the bare base-32 key under the QR code (spaces and dashes allowed).
    nonisolated static func key(from text: String) -> Key? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.lowercased().hasPrefix("otpauth://") else {
            return base32(trimmed).map { Key(secret: $0) }
        }
        guard let parts = URLComponents(string: trimmed), parts.host?.lowercased() == "totp" else { return nil }
        func value(_ name: String) -> String? { parts.queryItems?.first { $0.name.lowercased() == name }?.value }
        guard let secret = value("secret").flatMap(base32) else { return nil }
        var key = Key(secret: secret)
        if let digits = value("digits").flatMap(Int.init), (6...8).contains(digits) { key.digits = digits }
        if let period = value("period").flatMap(Int.init), (10...120).contains(period) { key.period = period }
        if let name = value("algorithm"), let algorithm = Algorithm(rawValue: name.uppercased()) { key.algorithm = algorithm }
        return key
    }

    nonisolated static func base32(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, buffer = 0
        var out = Data()
        for character in text.uppercased() where character != " " && character != "-" && character != "=" {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
                buffer &= (1 << bits) - 1
            }
        }
        return out.isEmpty ? nil : out
    }

    nonisolated static func code(for key: Key, at date: Date = Date()) -> String {
        var counter = UInt64(max(0, floor(date.timeIntervalSince1970 / Double(key.period)))).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let symmetric = SymmetricKey(data: key.secret)
        let mac: [UInt8]
        switch key.algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symmetric))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: symmetric))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: symmetric))
        }
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let truncated = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<key.digits { modulus *= 10 }
        let digits = String(truncated % modulus)
        return String(repeating: "0", count: key.digits - digits.count) + digits
    }

    nonisolated static func secondsLeft(_ key: Key, at date: Date = Date()) -> Int {
        let period = Double(key.period)
        return Int(period - date.timeIntervalSince1970.truncatingRemainder(dividingBy: period))
    }

    /// 123456 as "123 456", for reading across.
    nonisolated static func spaced(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let half = code.index(code.startIndex, offsetBy: code.count / 2)
        return code[..<half] + " " + code[half...]
    }
}
