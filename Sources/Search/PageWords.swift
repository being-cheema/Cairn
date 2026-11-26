import CryptoKit
import Foundation

// A page's words as they are kept and compared, for the two things that keep
// them: pin snapshots (PinChanges) and page watchers (PageWatch). Pure, apart
// from the small files at the end.
//
// Both are off until switched on in Settings › Privacy, and everything they
// write goes through here: a folder and files only you can open, at most so
// much text, with anything shaped like a card number, a labelled password or
// code, or a common kind of key taken out first (TypedSecrets). That goes by
// shapes: a secret a page prints some other way is kept as it is. Form
// fields are never read at all (PageScripts.markdown).

enum PageWords {
    static let longest = 200_000

    /// What is kept of what a page said.
    static func kept(_ text: String) -> String {
        // Hidden before it is cut, or the cut could leave half of one.
        let clean = TypedSecrets.hidden(in: text)
        return clean.count > longest ? String(clean.prefix(longest)) : clean
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The things that change on every visit and say nothing: how long ago,
    /// and a clock that counts seconds.
    private static let ticking = [
        #"(?i)\b(\d+|an?|a few)\s*(s|sec|secs|seconds?|m|min|mins|minutes?|h|hr|hrs|hours?|d|days?|w|wk|wks|weeks?|mo|months?|y|yr|yrs|years?)\s+ago\b"#,
        #"(?i)\bjust now\b"#,
        #"\b\d{1,2}:\d{2}:\d{2}\b"#,
    ]

    /// The lines as they are compared: spaces evened out, the ticking parts
    /// blanked, empty lines gone.
    static func lines(_ text: String) -> [(said: String, compared: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let said = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !said.isEmpty else { return nil }
            var compared = said
            for pattern in ticking {
                compared = compared.replacingOccurrences(of: pattern, with: "…", options: .regularExpression)
            }
            return (said, compared)
        }
    }

    /// Whether the words changed in a way worth telling you about. A page
    /// that came up empty hasn't changed: it hasn't loaded.
    static func changed(from old: String, to new: String) -> Bool {
        let now = lines(new).map(\.compared)
        return !now.isEmpty && lines(old).map(\.compared) != now
    }

    struct Line: Equatable {
        enum Kind: Equatable { case same, added, removed, gap }
        let kind: Kind
        let text: String
    }

    /// What was taken out and put in, in order, with `around` unchanged
    /// lines kept beside each change and the rest left out.
    static func difference(from old: String, to new: String, around: Int = 1) -> [Line] {
        let before = lines(old), after = lines(new)
        var removed = Set<Int>(), added = Set<Int>()
        for change in after.map(\.compared).difference(from: before.map(\.compared)) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var all: [Line] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                all.append(Line(kind: .removed, text: before[i].said))
                i += 1
            } else if j < after.count, added.contains(j) {
                all.append(Line(kind: .added, text: after[j].said))
                j += 1
            } else if j < after.count {
                all.append(Line(kind: .same, text: after[j].said))
                i += 1
                j += 1
            } else {
                break
            }
        }
        var keep = IndexSet()
        for (index, line) in all.enumerated() where line.kind != .same {
            keep.insert(integersIn: max(0, index - around)..<min(all.count, index + around + 1))
        }
        var out: [Line] = []
        var last = -1
        for index in keep {
            if index > last + 1 { out.append(Line(kind: .gap, text: "…")) }
            out.append(all[index])
            last = index
        }
        if !out.isEmpty, last < all.count - 1 { out.append(Line(kind: .gap, text: "…")) }
        return out
    }

    /// The first thing new in the page, to be found in it again.
    static func firstAdded(from old: String, to new: String) -> String? {
        difference(from: old, to: new, around: 0).first { $0.kind == .added }?.text
    }

    // MARK: - files

    /// Written whole, readable by you alone from before anything is in it.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        let files = FileManager.default
        let folder = url.deletingLastPathComponent()
        try? files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard files.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        if rename(temporary.path, url.path) == 0 { return true }
        try? files.removeItem(at: temporary)
        return false
    }
}
