import Foundation

/// What is wrong with the passwords kept, worked out on this Mac from the
/// passwords themselves. Nothing is sent anywhere, and the report holds no
/// password: only which accounts are flagged and why.
enum PasswordHealth {
    enum Kind: String, CaseIterable, Identifiable {
        case reused = "Reused"
        case weak = "Weak"
        case old = "Old"
        case plain = "Sent unencrypted"
        var id: String { rawValue }

        /// One line under the count, so nothing hides in a tooltip.
        var detail: String {
            switch self {
            case .reused: "The same password on more than one account"
            case .weak: "Short, or among the most common"
            case .old: "Not changed in over a year"
            case .plain: "Kept from a page sent over plain http"
            }
        }

        /// The tooltip: the same, with what it can't know.
        var help: String {
            switch self {
            case .old: "Not changed in over a year (only where the date is known)"
            default: detail
            }
        }
    }

    /// What the check needs of one item; the password is dropped after.
    struct Entry {
        let id: String
        let name: String
        let user: String
        let password: String
        let changed: Date?
        let clear: Bool
    }

    struct Finding: Identifiable, Equatable {
        let id: String
        let name: String
        let user: String
        let kinds: [Kind]
        /// One line a row can show: "Same password on 3 accounts · Short".
        let why: String
    }

    struct Report: Equatable {
        var checked = 0
        var findings: [Finding] = []

        func count(_ kind: Kind) -> Int { findings.filter { $0.kinds.contains(kind) }.count }
        var flagged: Set<String> { Set(findings.map(\.id)) }
    }

    /// A password not changed in this long is called old, when it is known
    /// when it was changed.
    nonisolated static let oldAfter: TimeInterval = 365 * 24 * 3600
    nonisolated static let shortest = 8

    /// Why a password is weak, or nil. Short, or one of the commonest, or one
    /// of them with only digits and marks added on the end ("password1!").
    nonisolated static func weakness(_ password: String) -> String? {
        if password.count < shortest { return "Short" }
        let lower = password.lowercased()
        if common.contains(lower) { return "Common" }
        let stem = String(lower.reversed().drop { !$0.isLetter }.reversed())
        if stem.count >= 4, stem != lower, common.contains(stem) { return "Common" }
        if Set(lower).count <= 2 { return "Repeats itself" }
        return nil
    }

    nonisolated static func check(_ entries: [Entry], now: Date = Date()) -> Report {
        var groups: [String: Int] = [:]
        for entry in entries { groups[entry.password, default: 0] += 1 }

        var report = Report(checked: entries.count)
        for entry in entries {
            var kinds: [Kind] = []
            var reasons: [String] = []
            if let same = groups[entry.password], same > 1 {
                kinds.append(.reused)
                reasons.append("Same password on \(same) accounts")
            }
            if let weak = weakness(entry.password) {
                kinds.append(.weak)
                reasons.append(weak)
            }
            if let changed = entry.changed, now.timeIntervalSince(changed) > oldAfter {
                kinds.append(.old)
                let years = Int(now.timeIntervalSince(changed) / oldAfter)
                reasons.append(years <= 1 ? "Not changed in over a year" : "Not changed in \(years) years")
            }
            if entry.clear {
                kinds.append(.plain)
                reasons.append("Kept from a page sent in the clear")
            }
            guard !kinds.isEmpty else { continue }
            report.findings.append(Finding(id: entry.id, name: entry.name, user: entry.user,
                                           kinds: kinds, why: reasons.joined(separator: " · ")))
        }
        // The most wrong first, then by name.
        report.findings.sort {
            $0.kinds.count == $1.kinds.count ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.kinds.count > $1.kinds.count
        }
        return report
    }

    /// The commonest passwords, lower-cased: what anyone tries first. Kept
    /// short and local; a longer list would need a download.
    nonisolated static let common: Set<String> = Set("""
    password passw0rd p@ssw0rd p@ssword password1 password12 password123 password1234 123456 1234567 12345678 123456789 1234567890 \
    12345 1234 123123 111111 000000 654321 666666 121212 112233 123321 123qwe 1q2w3e 1q2w3e4r 1q2w3e4r5t 1qaz2wsx qwerty qwerty1 \
    qwerty12 qwerty123 qwertyuiop qwertyui asdfgh asdfghjkl asdf1234 zxcvbn zxcvbnm abc123 abcd1234 abcdef abcdefg abcdefgh \
    iloveyou iloveyou1 ilovegod admin admin123 administrator root toor welcome welcome1 welcome123 login letmein letmein1 \
    master monkey dragon sunshine princess football baseball basketball soccer hockey batman superman spiderman starwars \
    pokemon naruto michael jordan jennifer jessica ashley daniel thomas robert hunter shadow killer trustno1 whatever \
    freedom secret secret123 hello hello123 hellohello test test123 testing testtest guest default changeme change123 \
    temp temp123 passpass pass1234 pass123 mypassword mypass myspace1 internet computer samsung google facebook twitter \
    youtube amazon apple1234 iphone cheese banana chocolate cookie summer winter spring autumn december january \
    flower butterfly love lovely loveme forever friends family angel angels heaven tigger bailey buster charlie maggie \
    ginger pepper hannah nicole jasmine matthew andrew joshua austin taylor yankees cowboys eagles liverpool chelsea \
    arsenal barcelona mustang ferrari porsche corvette harley ranger cameron access access14 passw0rd1 pa55word pa$$word \
    pa55w0rd q1w2e3r4 q1w2e3r4t5 qazwsx qazwsxedc zaq12wsx zaq1zaq1 aaaaaa aaaaaaaa 11111111 00000000 88888888 12341234 \
    11223344 987654321 987654 159753 147258369 1234abcd a1b2c3 a1b2c3d4 asd123 asdasd asdasdasd qweasd qweasdzxc qweqwe \
    qwe123 qwer1234 qwertyqwerty ninja azerty azerty123 motdepasse contraseña senha passwort geheim
    """.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\\" }).map(String.init))
}
