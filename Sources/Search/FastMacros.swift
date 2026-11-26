import Foundation

// Fast Macros: what a finished task of the panel's did, kept so it can be done
// again without asking a model.
//
// This file is the pure part: what may be recorded, what may be saved and what
// counts as the same control. Playing one is AgentControl's (replay), which
// sends each step through the very code a live agent's request goes through,
// so a replay has the same task store, address rules, questions and Stop. It
// starts only from your own click, never answers a question, and stops at the
// first thing that isn't as it was.
//
// A macro never holds a secret. One typed into a secret field, an address with
// a password or token in it, or text shaped like a card number or key makes
// the whole task unsaveable, rather than saved with a hole in it.

struct MacroStep: Codable, Equatable {
    enum Kind: String, Codable { case open, go, back, forward, click, type, press }

    var kind: Kind
    /// Which of the macro's tabs, counted in the order it opens them.
    var tab: Int
    /// For open and go.
    var url: String?
    /// The host the page was on when the step was taken.
    var host: String?
    /// What the control was, as the browser reads a page: its ARIA role and
    /// accessible name. The page's words: matched, never followed.
    var role: String?
    var name: String?
    /// For type.
    var text: String?
    var replace: Bool?
    var keys: Bool?
    var submit: Bool?
    /// For press.
    var key: String?

    /// A line of the list you read before running one.
    var said: String {
        let control = "\(role ?? "control") “\(AgentGate.quoted(name ?? ""))”"
        switch kind {
        case .open: return "Open \(url ?? "")"
        case .go: return "Go to \(url ?? "")"
        case .back: return "Go back"
        case .forward: return "Go forward"
        case .click: return "Click the \(control) on \(host ?? "the page")"
        case .type: return "Type “\(text ?? "")” into the \(control) on \(host ?? "the page")" + (submit == true ? " and submit" : "")
        case .press: return "Press \(key ?? "") on \(host ?? "the page")"
        }
    }
}

struct FastMacro: Codable, Equatable, Identifiable {
    var id = UUID()
    var created = Date()
    var name: String
    /// What you asked the task it came from, secrets hidden (TaskRecord).
    var prompt: String
    var steps: [MacroStep]
}

enum MacroRules {
    static let mostSteps = 40
    static let longestText = 2_000
    /// Keys that move or confirm. A single character is text under another
    /// name, with nothing to say which field it goes in.
    static let keys: Set<String> = ["enter", "return", "tab", "escape", "esc", "arrowup", "arrowdown",
                                    "arrowleft", "arrowright", "home", "end", "pageup", "pagedown", "space"]

    /// Why a step can't be kept or played, or nil. Asked when it is recorded
    /// and again when the file is read: a file can be edited.
    @MainActor
    static func refusal(_ step: MacroStep) -> String? {
        switch step.kind {
        case .open, .go:
            guard let url = step.url, AgentRules.webAddress(url) != nil else { return "an address wasn't a web address" }
            guard AgentRules.url(url) == url, TypedSecrets.hidden(in: url) == url else { return "an address had something secret in it" }
        case .back, .forward:
            break
        case .click, .type:
            guard let role = step.role, !role.isEmpty, let name = step.name, !name.isEmpty, step.host?.isEmpty == false
            else { return "a control had no name to find it by again" }
            if step.kind == .type {
                guard let text = step.text, text.count <= longestText, AgentRules.typeable(text) else { return "some typed text couldn't be kept" }
                guard TypedSecrets.hidden(in: text) == text else { return "it typed something that looks like a secret" }
            }
        case .press:
            guard let key = step.key, keys.contains(key.split(separator: "+").last.map { $0.lowercased() } ?? ""),
                  AgentRules.key(key) != nil else { return "it pressed a key that types a character" }
            guard step.host?.isEmpty == false else { return "a key had no page" }
        }
        return nil
    }

    @MainActor
    static func refusal(_ macro: FastMacro) -> String? {
        guard !macro.steps.isEmpty, macro.steps.count <= mostSteps else { return "it has no steps, or too many" }
        var tabs = 0
        for step in macro.steps {
            if let why = refusal(step) { return why }
            if step.kind == .open {
                guard step.tab == tabs else { return "its tabs are out of order" }
                tabs += 1
            } else {
                guard step.tab >= 0, step.tab < tabs else { return "a step has no tab" }
            }
        }
        return nil
    }

    enum Anchor: Equatable {
        /// The one control that is it: its handle.
        case found(String)
        case mismatch(String)
    }

    /// The control a step means, among the nodes of a fresh read. Exactly
    /// one of that role and name, able to be used, or nothing.
    static func anchor(_ step: MacroStep, among nodes: [[String: Any]]) -> Anchor {
        // A read marks names that read as orders (Quarantine); the name kept
        // is the page's own.
        let name = Quarantine.label(step.name ?? "")
        let same = nodes.filter { $0["role"] as? String == step.role && $0["name"] as? String == name }
        let what = "\(step.role ?? "control") “\(AgentGate.quoted(step.name ?? ""))”"
        guard let node = same.first, let handle = node["element"] as? String else { return .mismatch("The \(what) isn't on the page") }
        guard same.count == 1 else { return .mismatch("There are \(same.count) controls like the \(what)") }
        if node["disabled"] as? Bool == true { return .mismatch("The \(what) is disabled") }
        // Never a secret field, whatever it was when the macro was made.
        if step.kind == .type, node["redacted"] as? Bool == true { return .mismatch("The \(what) is a secret field now") }
        return .found(handle)
    }
}

/// What one turn of the panel's has done so far, towards a macro.
struct MacroRecorder: Equatable {
    private(set) var steps: [MacroStep] = []
    /// Why this turn can't be saved, once something makes it so. The first
    /// reason is the one kept.
    private(set) var spoiled: String?
    private var tabs: [UUID] = []

    mutating func spoil(_ why: String) {
        if spoiled == nil { spoiled = why }
        // Nothing of it is held on to.
        steps = []
    }

    @MainActor
    mutating func took(_ step: MacroStep, on tab: UUID) {
        guard spoiled == nil else { return }
        var step = step
        if step.kind == .open {
            step.tab = tabs.count
            tabs.append(tab)
        } else {
            guard let index = tabs.firstIndex(of: tab) else { return spoil("it used a tab this message didn't open") }
            step.tab = index
        }
        if let why = MacroRules.refusal(step) { return spoil(why) }
        guard steps.count < MacroRules.mostSteps else { return spoil("it took too many steps") }
        steps.append(step)
    }
}

/// Saved macros, a small JSON file each, readable by you alone; and the turns
/// of this run of the app that could become one, which are only in memory
/// until you press Save.
@MainActor
enum MacroStore {
    static let most = 50
    private static let longestFile = 256 * 1024

    nonisolated static var folder: URL { Store.file("Macros") }

    private(set) static var drafts: [UUID: MacroRecorder] = [:]

    /// By the task's record (TaskLedger).
    static func draft(_ record: UUID, _ recorder: MacroRecorder?) {
        drafts[record] = recorder
    }

    static func macro(from record: TaskRecord, _ recorder: MacroRecorder) -> FastMacro? {
        guard record.outcome == .completed, recorder.spoiled == nil else { return nil }
        let words = record.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let macro = FastMacro(name: TaskRecord.cut(words.isEmpty ? "Macro" : words, 60), prompt: record.prompt, steps: recorder.steps)
        return MacroRules.refusal(macro) == nil ? macro : nil
    }

    private static func file(_ id: UUID, in folder: URL) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    @discardableResult
    static func save(_ macro: FastMacro, in folder: URL = MacroStore.folder) -> Bool {
        guard MacroRules.refusal(macro) == nil, all(in: folder).count < most else { return false }
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(macro) else { return false }
        return files.createFile(atPath: file(macro.id, in: folder).path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Newest first. A file that isn't a macro that could be played is passed
    /// over.
    static func all(in folder: URL = MacroStore.folder) -> [FastMacro] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return found.filter { $0.pathExtension == "json" }.compactMap { url -> FastMacro? in
            guard ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max) <= longestFile,
                  let data = try? Data(contentsOf: url), let macro = try? decoder.decode(FastMacro.self, from: data),
                  MacroRules.refusal(macro) == nil else { return nil }
            return macro
        }.sorted { $0.created > $1.created }
    }

    static func remove(_ id: UUID, in folder: URL = MacroStore.folder) {
        try? FileManager.default.removeItem(at: file(id, in: folder))
    }

    /// With the task history cleared, what could be saved from it goes too.
    /// A macro you saved yourself stays until you delete it.
    static func forgetDrafts() {
        drafts = [:]
    }

    /// What goes in the panel's box after a replay, for you to send or not.
    nonisolated static func summaryRequest(_ macro: FastMacro) -> String {
        "I ran my saved macro “\(macro.name)” and attached the page it ended on. Summarize what it shows, for what I first asked: “\(TaskRecord.cut(macro.prompt, 600))”."
    }
}
