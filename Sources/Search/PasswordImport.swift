import Foundation

/// A passwords file, read for a preview and written only when told to.
///
/// Other managers and browsers all write the same few things in a CSV — an
/// address, a name, a password, and sometimes a title, notes and a code
/// secret — under their own column names. The format is told by those names,
/// not asked for: the Passwords app and Safari, Chrome and its relatives,
/// Firefox, Bitwarden (CSV or JSON), 1Password, LastPass, KeePass, Dashlane.
/// Nothing is written until Bring in is pressed, and the file is never kept.
enum PasswordImport {
    struct Candidate: Equatable {
        var host: String
        var user: String
        var password: String
        var clear: Bool
        var extras: Extras
        var id: String { host + "\u{1}" + user.lowercased() }
    }

    /// Why a row couldn't be taken. Never holds a secret: it is shown.
    struct Problem: Equatable {
        let row: Int
        let why: String
    }

    struct Parsed {
        /// What the file looks like, for the preview: "Chrome, Edge or Brave".
        var source: String
        var candidates: [Candidate]
        var problems: [Problem]
    }

    /// What bringing the file in would do, sorted before anything is written.
    struct Plan {
        var fresh: [Candidate] = []
        /// Already kept, with this very password.
        var same: [Candidate] = []
        /// Already kept, with another password.
        var different: [Candidate] = []
        var problems: [Problem] = []
        var source = ""
        var total: Int { fresh.count + same.count + different.count }
    }

    enum Duplicates: String, CaseIterable, Identifiable {
        /// What is kept stays as it is.
        case skip = "Keep what I have"
        /// The file's password (and notes, name, code key) replaces it.
        case update = "Use the file's"
        var id: String { rawValue }
    }

    struct Result: Equatable {
        var added = 0
        var updated = 0
        var skipped = 0
        var failed = 0
    }

    // MARK: - reading

    /// Nil for a file that isn't a passwords file at all.
    nonisolated static func parse(_ data: Data) -> Parsed? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let head = text.drop { $0.isWhitespace }.first
        if head == "{" || head == "[" { return parse(json: data) }
        return parse(csv: text)
    }

    /// The column names a header may use for each thing, lower-cased.
    private static let urlNames = ["url", "login_uri", "login url", "website", "web site", "site", "web address", "address", "uri"]
    private static let userNames = ["username", "login_username", "login name", "user name", "user", "login", "email", "e-mail", "email address"]
    private static let passNames = ["password", "login_password", "pass", "passwd"]
    private static let titleNames = ["title", "name", "account", "label"]
    private static let noteNames = ["notes", "note", "extra", "comments", "comment"]
    private static let codeNames = ["otpauth", "login_totp", "totp", "totp secret", "one-time password", "otp"]

    nonisolated static func parse(csv text: String) -> Parsed? {
        var rows = Vault.parse(csv: text)
        guard !rows.isEmpty else { return nil }
        let header = rows.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let urlAt = column(urlNames), let passAt = column(passNames) else { return nil }
        let userAt = column(userNames), titleAt = column(titleNames), notesAt = column(noteNames), codeAt = column(codeNames)

        var candidates: [Candidate] = []
        var problems: [Problem] = []
        func cell(_ row: [String], _ at: Int?) -> String {
            guard let at, row.indices.contains(at) else { return "" }
            return row[at].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (index, row) in rows.enumerated() {
            let number = index + 2
            let address = cell(row, urlAt)
            let password = row.indices.contains(passAt) ? row[passAt] : ""
            guard !password.isEmpty else { problems.append(Problem(row: number, why: "No password")); continue }
            let host = Vault.host(of: address)
            guard !host.isEmpty else {
                problems.append(Problem(row: number, why: address.isEmpty ? "No address" : "Not a website address"))
                continue
            }
            let user = cell(row, userAt)
            let extras = makeExtras(host: host, title: cell(row, titleAt), notes: cell(row, notesAt), code: cell(row, codeAt))
            candidates.append(Candidate(host: host, user: user, password: password,
                                        clear: address.lowercased().hasPrefix("http://"), extras: extras))
        }
        return Parsed(source: describe(header), candidates: candidates, problems: problems)
    }

    /// What the file looks like, from the names it gives its columns.
    private static func describe(_ header: [String]) -> String {
        let names = Set(header)
        if names.contains("login_uri") { return "Bitwarden" }
        if names.contains("grouping") && names.contains("extra") { return "LastPass" }
        if names.contains("httprealm") || names.contains("formactionorigin") { return "Firefox" }
        if names.contains("login name") && names.contains("web site") { return "KeePass" }
        if names.contains("otpauth") && names.contains("favorite") { return "1Password" }
        if names.contains("otpauth") && names.contains("title") { return "the Passwords app or Safari" }
        if names.contains("name") && names.contains("note") { return "Chrome, Edge, Brave or similar" }
        return "a passwords file"
    }

    /// A title only when it says something the address doesn't, so a column of
    /// site names doesn't turn into a column of titles.
    private static func makeExtras(host: String, title: String, notes: String, code: String) -> Extras {
        var extras = Extras()
        let plain = title.lowercased()
        let site = Vault.registrable(host)
        let name = site.split(separator: ".").first.map(String.init) ?? site
        if !plain.isEmpty, plain != host, plain != site, plain != name, plain != "www." + host { extras.title = title }
        if !notes.isEmpty { extras.notes = notes }
        if !code.isEmpty { extras.totp = code }
        return extras
    }

    /// Bitwarden's JSON export: logins only; cards, identities and notes
    /// aren't passwords.
    nonisolated static func parse(json data: Data) -> Parsed? {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = top["items"] as? [[String: Any]]
        else { return nil }
        var candidates: [Candidate] = []
        var problems: [Problem] = []
        for (index, item) in items.enumerated() {
            guard (item["type"] as? Int) == 1, let login = item["login"] as? [String: Any] else { continue }
            let number = index + 1
            guard let password = login["password"] as? String, !password.isEmpty else {
                problems.append(Problem(row: number, why: "No password")); continue
            }
            let addresses = ((login["uris"] as? [[String: Any]]) ?? []).compactMap { $0["uri"] as? String }
            guard let first = addresses.first(where: { !Vault.host(of: $0).isEmpty }) else {
                problems.append(Problem(row: number, why: addresses.isEmpty ? "No address" : "Not a website address")); continue
            }
            let host = Vault.host(of: first)
            var extras = makeExtras(host: host, title: (item["name"] as? String) ?? "", notes: (item["notes"] as? String) ?? "",
                                    code: (login["totp"] as? String) ?? "")
            let others = addresses.filter { $0 != first && !Vault.host(of: $0).isEmpty }
            if !others.isEmpty { extras.urls = others }
            candidates.append(Candidate(host: host, user: (login["username"] as? String) ?? "", password: password,
                                        clear: first.lowercased().hasPrefix("http://"), extras: extras))
        }
        return Parsed(source: "Bitwarden", candidates: candidates, problems: problems)
    }

    // MARK: - planning

    /// Sorts what the file holds against what is kept. A login listed twice in
    /// the file counts once (the first), and the second is told as a problem.
    /// `secret` is read only for those already kept, to tell a same password
    /// from another.
    nonisolated static func plan(_ parsed: Parsed, kept: [Kept], secret: (Kept) -> String?) -> Plan {
        var plan = Plan(problems: parsed.problems, source: parsed.source)
        var have: [String: Kept] = [:]
        for item in kept { have[item.host + "\u{1}" + item.user.lowercased()] = item }
        var seen = Set<String>()
        for candidate in parsed.candidates {
            guard seen.insert(candidate.id).inserted else {
                plan.problems.append(Problem(row: 0, why: "\(candidate.host) listed twice for the same account")); continue
            }
            if let existing = have[candidate.id] {
                if secret(existing) == candidate.password { plan.same.append(candidate) } else { plan.different.append(candidate) }
            } else {
                plan.fresh.append(candidate)
            }
        }
        return plan
    }

    // MARK: - writing

    /// Writes the plan. `write` is Vault.save in life, a stand-in in a test.
    nonisolated static func commit(_ plan: Plan, duplicates: Duplicates,
                                   write: (Candidate, _ keepExtras: Bool) -> Bool) -> Result {
        var result = Result()
        for candidate in plan.fresh { write(candidate, false) ? (result.added += 1) : (result.failed += 1) }
        switch duplicates {
        case .skip:
            result.skipped = plan.same.count + plan.different.count
        case .update:
            result.skipped = plan.same.count
            // Notes and the like the file doesn't have stay as they are.
            for candidate in plan.different { write(candidate, candidate.extras.isEmpty) ? (result.updated += 1) : (result.failed += 1) }
        }
        return result
    }
}
