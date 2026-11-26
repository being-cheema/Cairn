import Foundation

// What each of the panel's tasks did, kept on this Mac so you can look back:
// what you asked, where Claude went, what you were asked to approve and what
// you said, how it ended and which tabs it left you. Secrets you typed are
// taken out (TypedSecrets), and Settings can turn the whole thing off.
//
// One small JSON file to a task in the Tasks folder, readable by you alone,
// and only so many of them. Kept: your own typed words, site names, the
// browser's words for each question, and the titles and addresses of the
// tabs left to you, with secrets taken out of addresses. Never kept: what
// Claude answered, a page's text, anything attached with "@", or anything
// from a tab of yours. Clearing all history removes the lot.

struct TaskRecord: Codable, Equatable, Identifiable {
    enum Outcome: String, Codable { case completed, stopped, denied, failed }

    struct Receipt: Codable, Equatable {
        let time: Date
        /// AgentGate's reason: pay, send, signIn, submit, leave.
        let reason: String
        /// The browser's words for the question, the page's quoted and cut.
        let what: String
        /// approved, declined, timedOut, or ended: the task went first.
        let answer: String
    }

    struct Page: Codable, Equatable {
        let title: String
        let url: String
    }

    var id = UUID()
    var time = Date()
    var prompt: String
    var model: String?
    var hosts: [String] = []
    var approvals: [Receipt] = []
    var outcome: Outcome = .completed
    var tabs: [Page] = []

    static let longestPrompt = 2_000, mostHosts = 50, mostReceipts = 50, mostTabs = 20

    static func cut(_ text: String, _ most: Int) -> String {
        text.count > most ? String(text.prefix(most)) + "…" : text
    }

    init(prompt: String, model: String?) {
        // Hidden before it is cut, or the cut could leave half of one.
        self.prompt = Self.cut(TypedSecrets.hidden(in: prompt), Self.longestPrompt)
        self.model = model
    }

    mutating func visited(_ host: String) {
        let host = Self.cut(host.lowercased(), 200)
        guard !host.isEmpty, hosts.count < Self.mostHosts, !hosts.contains(host) else { return }
        hosts.append(host)
    }

    mutating func asked(reason: String, what: String, answer: String, at time: Date = Date()) {
        guard approvals.count < Self.mostReceipts else { return }
        approvals.append(Receipt(time: time, reason: reason, what: Self.cut(what, 200), answer: answer))
    }

    mutating func left(title: String, url: String) {
        let page = Page(title: Self.cut(title, 200), url: Self.cut(url, 2_000))
        guard tabs.count < Self.mostTabs, !tabs.contains(page) else { return }
        tabs.append(page)
    }

    /// How a turn ended: your Stop first, then any question you said no to,
    /// then whether it failed.
    static func outcome(stopped: Bool, failed: Bool, approvals: [Receipt]) -> Outcome {
        if stopped { return .stopped }
        if approvals.contains(where: { $0.answer == "declined" }) { return .denied }
        return failed ? .failed : .completed
    }

    /// The pages that may be opened again in your own tabs: web addresses on
    /// the public web, nothing else. Opening one there is opening it signed
    /// in, which is why it waits for your click and shows the address first.
    @MainActor var reopenable: [URL] {
        tabs.compactMap { page in
            AgentRules.webAddress(page.url).flatMap { PrivateNetwork.refuses($0, allowed: []) ? nil : $0 }
        }
    }

    /// What "Follow Up in New Task" puts in the box, for you to read, change
    /// and send. Your own earlier words and the addresses; not the tabs'
    /// titles, which are the websites' words and would read as yours.
    var followUp: String {
        var out = "Follow up on an earlier task of mine. I asked: “\(Self.cut(prompt, 600))”."
        let addresses = tabs.prefix(6).map { page -> String in
            guard var parts = URLComponents(string: page.url) else { return "" }
            parts.query = nil
            parts.fragment = nil
            return Self.cut(parts.string ?? "", 300)
        }.filter { !$0.isEmpty }
        if !addresses.isEmpty { out += "\nPages it left me: " + addresses.joined(separator: " ") }
        return out + "\nNow: "
    }
}

@MainActor
enum TaskLedger {
    static let most = 200
    private static let longestFile = 256 * 1024

    nonisolated static var folder: URL { Store.file("Tasks") }

    private static func file(_ id: UUID, in folder: URL) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    /// `amending`: more about a task already written. A record deleted or
    /// cleared since is not brought back.
    static func save(_ record: TaskRecord, amending: Bool = false, in folder: URL = TaskLedger.folder) {
        // Cleared since this task began, as it ran: it was cleared too.
        if let at = cleared[folder.path], record.time <= at { return }
        let files = FileManager.default
        if amending, !files.fileExists(atPath: file(record.id, in: folder).path) { return }
        try? files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        let url = file(record.id, in: folder)
        let new = !files.fileExists(atPath: url.path)
        // Made readable by you alone before anything is in it, then swapped in.
        let temporary = folder.appendingPathComponent(".\(record.id.uuidString).tmp")
        guard files.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, url.path) != 0 { try? files.removeItem(at: temporary) }
        if new { prune(in: folder) }
    }

    /// Newest first. A file that can't be read as a record is passed over.
    static func all(in folder: URL = TaskLedger.folder) -> [TaskRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return found.filter { $0.pathExtension == "json" }.compactMap { url -> TaskRecord? in
            guard ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max) <= longestFile,
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(TaskRecord.self, from: data)
        }.sorted { $0.time > $1.time }
    }

    private static func prune(in folder: URL) {
        for record in all(in: folder).dropFirst(most) { remove(record.id, in: folder) }
    }

    static func remove(_ id: UUID, in folder: URL = TaskLedger.folder) {
        try? FileManager.default.removeItem(at: file(id, in: folder))
        MacroStore.draft(id, nil)
    }

    /// When each folder was last cleared, in this run of the app. A task still
    /// running then writes its record afterwards; nothing running outlives
    /// the app, so this needn't either.
    private static var cleared: [String: Date] = [:]

    static func removeAll(in folder: URL = TaskLedger.folder) {
        cleared[folder.path] = Date()
        MacroStore.forgetDrafts()
        try? FileManager.default.removeItem(at: folder)
    }
}
