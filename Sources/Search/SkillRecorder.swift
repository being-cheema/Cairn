import Foundation

// Record Skill: you do something once in your own tab, with Record Skill on,
// and Cairn writes it as a playbook (SKILL.md in the Skills folder) that
// Claude can follow later in tabs of its own.
//
// Only while you have it on, only your own steps, only in the tab in front.
// Nothing from the page is kept but the names of the controls you used (they
// are the words the steps are written with, and are in the file you review
// before it is used). What you type into a box is never in the file: it
// becomes a parameter, named for the box, and the file says only that it was
// typed. A password, card or code box is not even that: the step says to
// hand the tab to you. Nothing is written until you name it, and nothing at
// all if you cancel.

struct RecordedStep: Equatable {
    enum Kind: String { case open, click, type, choose, key }
    var kind: Kind
    var url = ""
    var role = ""
    var name = ""
    var secret = false
    var checked: Bool?
    var key = ""
}

enum SkillRecording {
    static let most = 60

    /// The page script's events, and the addresses seen, as steps. Clicks
    /// into a text box are not steps (the typing is), the same typing twice
    /// in a row is one, and a click on a control the page re-reported is not
    /// doubled.
    static func steps(from events: [[String: Any]]) -> [RecordedStep] {
        var out: [RecordedStep] = []
        for event in events {
            var step = RecordedStep(kind: .click)
            step.role = event["role"] as? String ?? ""
            step.name = clean(event["name"] as? String ?? "")
            step.secret = event["secret"] as? Bool ?? false
            switch event["k"] as? String {
            case "open":
                step.kind = .open
                step.url = event["url"] as? String ?? ""
                guard !step.url.isEmpty else { continue }
            case "click":
                if ["textbox", "searchbox", "spinbutton"].contains(step.role) { continue }
                if step.role == "combobox" || step.role == "listbox" { continue }
            case "change":
                step.kind = .type
                if step.role == "combobox" || step.role == "listbox" { step.kind = .choose }
                if ["checkbox", "radio", "switch"].contains(step.role) { continue }
            case "key":
                step.kind = .key
                step.key = event["key"] as? String ?? ""
            default:
                continue
            }
            if out.last == step, step.kind != .click { continue }
            if step.kind == .type, let last = out.last, last.kind == .type, last.role == step.role, last.name == step.name {
                out.removeLast()
            }
            out.append(step)
        }
        return Array(out.prefix(most))
    }

    private static func clean(_ text: String) -> String { AgentGate.quoted(text) }

    /// `Search results` → `search-results`: a name for a parameter or a file.
    static func slug(_ text: String, fallback: String) -> String {
        let words = text.lowercased().unicodeScalars.map { $0.isASCII && (CharacterSet.alphanumerics.contains($0)) ? String($0) : "-" }.joined()
        let squashed = words.split(separator: "-").joined(separator: "-")
        return squashed.isEmpty ? fallback : String(squashed.prefix(24))
    }

    /// The playbook. `name` is its name after the "/". Parameters are the
    /// boxes typed into, in order, named for the box.
    static func markdown(name: String, steps: [RecordedStep]) -> (text: String, parameters: [String]) {
        var parameters: [String] = []
        var lines: [String] = []
        for step in steps {
            let n = lines.count + 1
            switch step.kind {
            case .open:
                lines.append("\(n). Open \(step.url) in a tab of your own.")
            case .click:
                lines.append("\(n). Click the \(step.role.isEmpty ? "control" : step.role) named “\(step.name)”.")
            case .type where step.secret:
                lines.append("\(n). The “\(step.name)” box takes a password, card or code: don't fill it. Call wait_for_sign_in so that I do, then go on.")
            case .type:
                var param = slug(step.name, fallback: "text")
                if parameters.contains(param) { param += "-\(parameters.count + 1)" }
                parameters.append(param)
                lines.append("\(n). Type <\(param)> into the \(step.role) named “\(step.name)”.")
            case .choose:
                var param = slug(step.name, fallback: "choice")
                if parameters.contains(param) { param += "-\(parameters.count + 1)" }
                parameters.append(param)
                lines.append("\(n). Choose <\(param)> in the menu named “\(step.name)”.")
            case .key:
                lines.append("\(n). Press \(step.key).")
            }
        }
        let hint = parameters.map { "<\($0)>" }.joined(separator: " ")
        var body = """
            Do this in Cairn, in tabs of your own, reading the page before each step and finding each control by its role and name. \
            It was recorded from a person doing it once; if a control isn't there, stop and say which.
            Anything that sends, pays or signs in is still asked of me first.

            """
        body += lines.joined(separator: "\n")
        if !parameters.isEmpty {
            body += "\n\nThe values for \(hint), in that order, are what I typed after the playbook's name: $ARGUMENTS\nIf any is missing, ask me before you start."
        }
        let title = name
        let text = """
            ---
            name: \(title)
            description: Recorded steps on \(hostOf(steps)): \(steps.count) step\(steps.count == 1 ? "" : "s")
            argument_hint: \(hint)
            ---
            \(body)
            """
        return (text, parameters)
    }

    private static func hostOf(_ steps: [RecordedStep]) -> String {
        steps.first { $0.kind == .open }.flatMap { URL(string: $0.url)?.host() } ?? "a page"
    }

    /// Written as Skills/<name>/SKILL.md, never over one that is there (-2,
    /// -3…), readable by you alone. Nil when it can't be written or the
    /// result would not load as a playbook.
    @discardableResult
    static func save(_ text: String, as name: String, in folder: URL = Playbooks.folder) -> URL? {
        guard let called = Playbooks.name(name), Playbooks.parse(text, fileName: called) != nil else { return nil }
        let files = FileManager.default
        var unique = called, k = 1
        while files.fileExists(atPath: folder.appendingPathComponent(unique).path) { k += 1; unique = "\(called)-\(k)" }
        let room = folder.appendingPathComponent(unique, isDirectory: true)
        do {
            try files.createDirectory(at: room, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = room.appendingPathComponent("SKILL.md")
            let fixed = text.replacingOccurrences(of: "name: \(called)\n", with: "name: \(unique)\n")
            try Data(fixed.utf8).write(to: file, options: [.atomic])
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file
        } catch {
            return nil
        }
    }
}

extension PageScripts {
    /// Listens, in Search's world, for what you do in the page, and gives
    /// what it heard since last asked. Only real events of yours
    /// (isTrusted): a page's own script clicking things is not you. A secret
    /// box says it was changed and nothing of what it holds.
    static func record() -> String {
        call(#"""
        (function () {
          var R = globalThis.__cairnRec;
          if (!R) {
            R = globalThis.__cairnRec = { out: [] };
            function target(e) {
              var el = e.target && e.target.closest ? e.target.closest(SEL) : null;
              return el && wanted(el) ? el : null;
            }
            function note(kind, el, more) {
              var map = eids(candidates());
              var item = { k: kind, eid: eidFor(el, map), role: role(el), name: name(el).slice(0, 60), secret: secret(el) };
              for (var key in more) item[key] = more[key];
              if (R.out.length < 200) R.out.push(item);
            }
            document.addEventListener('click', function (e) { if (!e.isTrusted) return; var el = target(e); if (el) note('click', el, {}); }, true);
            document.addEventListener('change', function (e) {
              if (!e.isTrusted) return;
              var el = e.target;
              if (!el || !/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)) return;
              note('change', el, {});
            }, true);
            document.addEventListener('keydown', function (e) {
              if (!e.isTrusted || e.key !== 'Enter') return;
              var el = target(e) || document.activeElement;
              if (el && el.tagName) note('key', el, { key: 'Enter' });
            }, true);
          }
          var out = R.out;
          R.out = [];
          return JSON.stringify({ events: out, url: location.href });
        })
        """#, [])
    }
}

/// The recording in hand, for one window: polls the tab in front while on.
@MainActor
final class SkillRecorder: ObservableObject {
    @Published private(set) var recording = false
    private var events: [[String: Any]] = []
    private var lastPlace = ""
    private var timer: Timer?
    private weak var browser: Browser?

    var count: Int { SkillRecording.steps(from: events).count }

    func start(in browser: Browser) {
        guard !recording else { return }
        self.browser = browser
        events = []
        lastPlace = ""
        recording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// What was recorded, and nothing kept: the caller names it or drops it.
    func stop() -> [RecordedStep] {
        timer?.invalidate()
        timer = nil
        recording = false
        defer { events = [] }
        return SkillRecording.steps(from: events)
    }

    /// A tab that is yours, signed in or not, in front, and not a private
    /// one, an agent's, or a site you closed to agents.
    private func poll() {
        guard recording, let tab = browser?.active, tab.isWeb, !tab.shy, !tab.agent, !AgentControl.isVaulted(tab),
              let web = tab.built, !tab.asleep else { return }
        web.evaluateJavaScript(PageScripts.record(), in: nil, in: Web.world) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.recording, case .success(let value) = result, let text = value as? String,
                      let out = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
                if let address = (out["url"] as? String).flatMap(URL.init(string:)), ["http", "https"].contains(address.scheme ?? ""),
                   let host = address.host() {
                    // The place, never its query or fragment: those carry values.
                    let place = "\(address.scheme ?? "https")://\(host)\(address.path)"
                    if place != self.lastPlace {
                        self.lastPlace = place
                        self.events.append(["k": "open", "url": place])
                    }
                }
                self.events += out["events"] as? [[String: Any]] ?? []
            }
        }
    }
}
