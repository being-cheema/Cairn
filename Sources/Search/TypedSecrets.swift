import Foundation

// Secrets you typed into the panel's box, kept out of Task History.
//
// Only the saved record is changed: what you send goes to Claude as typed.
// This knows shapes, not meanings: card numbers that pass their check digit,
// a word or number said to be a password or code ("password is …", "pin=…"),
// and the common shapes of keys and tokens. A secret written any other way
// is kept as typed, and so is all but the first word of one written as
// several words without quotes. History can be turned off in Settings.

enum TypedSecrets {
    static let mark = "[hidden]"

    static func hidden(in text: String) -> String {
        var out = text
        for pattern in shapes { out = replace(pattern, in: out) { _ in true } }
        // Not what AgentRules.scrubbed already took out of an address.
        out = replace(labelled, in: out, group: 2) { !$0.hasPrefix("redacted") }
        out = replace(numbered, in: out, group: 2) { _ in true }
        return replace(cardLike, in: out) { luhn($0) }
    }

    private static let shapes = [
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#,
        #"\bsk-[A-Za-z0-9_\-]{16,}"#,
        #"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{22,})"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#,
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        #"(?i)(?<=\bbearer )[A-Za-z0-9._~+/\-]{16,}=*"#,
    ]

    /// A name for a secret, then "is", ":" or "=", then the thing itself.
    private static let labelled =
        #"(?i)\b(password|passwd|pwd|passcode|passphrase|secret|api[ _\-]?key|access token|token)(?:\s+is\b:?\s*|\s*[:=]\s*)("[^"\n]*"|'[^'\n]*'|“[^”\n]*”|[^\s"'“]+)"#
    /// A code that is digits needs no "is": "cvv 321", "the code is 493021".
    private static let numbered =
        #"(?i)\b(pin|cvv|cvc|otp|one[- ]time code|verification code|security code|2fa code)(?:\s+is\b:?\s*|\s*[:=]\s*|\s+)(\d{3,10})\b"#
    private static let cardLike = #"(?<![\w+])(?:\d[ \-]?){12,18}\d(?!\w)"#

    private static func luhn(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { total, each in
            let doubled = each.offset % 2 == 1 ? each.element * 2 : each.element
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    private static func replace(_ pattern: String, in text: String, group: Int = 0, when: (String) -> Bool) -> String {
        guard let found = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        for match in found.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range(at: group), in: out), when(String(out[range])) else { continue }
            out.replaceSubrange(range, with: mark)
        }
        return out
    }
}
