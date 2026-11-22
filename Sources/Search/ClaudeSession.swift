import Foundation

// One conversation with the person's own Claude Code, in the side panel.
//
// It starts the program the first time you send something, keeps it for the
// following messages (so it remembers what you said a moment ago, with nothing
// written to disk), and ends it when the panel is closed, Stop is pressed, or
// the window goes. What it says comes back as text and is shown as text: never
// markdown, a link to follow or a picture to fetch. What a tool returned to it
// — the words of a page — is never shown here at all, so a page can't speak in
// the model's voice.
//
// The browser side is not here: it is AgentControl, which asks you in the
// window, with Allow, the first time Claude Code uses a tool, and which keeps
// it to tabs it opened, away from passwords and the rest (see its notes).

@MainActor
final class ClaudeSession: ObservableObject {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let question: String
        var answer = ""
        /// What it did, as the person would say it, in order.
        var steps: [String] = []
        var done = false
        var failed: String?
    }

    /// Why it can't start, as the panel says it.
    enum Problem: Equatable {
        case notInstalled
        case notSigned
        case noScript
        case agentsOff
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var running = false
    @Published private(set) var problem: Problem?
    @Published var draft = ""

    private let agentsOn: () -> Bool
    private let executable: URL?
    private let verify: (URL) -> Bool
    private let script: URL?
    private let world: String?
    private let options: () -> ClaudeCode.Options

    private var process: Process?
    private var input: FileHandle?
    private var folder: URL?
    private var pending = Data()
    /// Words of the message in progress arrived as they were written, so the
    /// finished message repeating them is not shown twice.
    private var streamed = false
    /// The next words open a new paragraph.
    private var needBreak = false
    /// Tools already shown for this turn: told as they begin and again in the
    /// finished message.
    private var seenTools = Set<String>()
    /// A line longer than this is not the program speaking: it is ended.
    private static let longest = 8 << 20

    init(agentsOn: @escaping () -> Bool,
         executable: URL? = nil,
         verify: @escaping (URL) -> Bool = ClaudeCode.signedByAnthropic,
         script: URL? = nil,
         world: String? = Store.world,
         options: @escaping () -> ClaudeCode.Options = { ClaudeCode.Options() }) {
        self.agentsOn = agentsOn
        self.executable = executable
        self.verify = verify
        self.script = script
        self.world = world
        self.options = options
    }

    // MARK: - sending

    func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        // Coding agents are the person's to allow, in Settings: this is one.
        guard agentsOn() else { problem = .agentsOff; return }
        if process == nil, !start() { return }
        problem = nil
        draft = ""
        turns.append(Turn(question: text))
        seenTools = []
        streamed = false
        needBreak = false
        running = true
        let line = ClaudeCode.message(text)
        do {
            try input?.write(contentsOf: line)
        } catch {
            finish(failing: "Couldn't reach Claude Code. Try again.")
            stop()
        }
    }

    /// A conversation from the start: the run ended, what was said forgotten.
    func newChat() {
        stop()
        turns = []
        problem = nil
        draft = ""
    }

    /// What it is doing now, while it is: the last thing it said it was at.
    var step: String? { running ? turns.last?.steps.last : nil }

    /// Ends the run, for Stop, for closing the panel, for a window going.
    func stop() {
        let wasRunning = running
        let live = process
        process = nil
        input = nil
        live?.terminationHandler = nil
        (live?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (live?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if live?.isRunning == true { live?.terminate() }
        cleanUp()
        if wasRunning { finish(failing: "Stopped.") }
        running = false
    }

    // MARK: - starting

    private func start() -> Bool {
        guard let claude = executable ?? ClaudeCode.locate() else { problem = .notInstalled; return false }
        guard verify(claude) else { problem = .notSigned; return false }
        guard let script = script ?? ClaudeCode.mcpScript() else { problem = .noScript; return false }

        // A folder for this run alone, to be empty and to go.
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent("cairn-claude-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try ClaudeCode.mcpConfig(script: script, world: world).write(to: home.appendingPathComponent("mcp.json"))
        } catch {
            try? files.removeItem(at: home)
            problem = .noScript
            return false
        }

        let run = Process()
        run.executableURL = claude
        run.arguments = ClaudeCode.arguments(config: home.appendingPathComponent("mcp.json"), options: options())
        run.currentDirectoryURL = home
        run.environment = ClaudeCode.environment()
        let toIt = Pipe(), fromIt = Pipe(), errors = Pipe()
        run.standardInput = toIt
        run.standardOutput = fromIt
        run.standardError = errors

        fromIt.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.take(data) } }
        }
        // Read and dropped: a full pipe would stop it, and what it says there
        // may carry a page's words, so none of it is kept or logged.
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        run.terminationHandler = { [weak self] ended in
            let code = ended.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(run: ended, code: code) } }
        }
        do {
            try run.run()
        } catch {
            try? files.removeItem(at: home)
            problem = .notInstalled
            return false
        }
        process = run
        // A write to a program that has gone fails; it must not raise SIGPIPE.
        _ = fcntl(toIt.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        input = toIt.fileHandleForWriting
        folder = home
        pending = Data()
        return true
    }

    private func cleanUp() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        pending = Data()
    }

    // MARK: - what comes back

    private func take(_ data: Data) {
        pending.append(data)
        if pending.count > Self.longest {
            finish(failing: "Claude Code sent more than expected, so it was stopped.")
            stop()
            return
        }
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if let text = String(data: line, encoding: .utf8) { apply(ClaudeCode.events(from: text)) }
        }
    }

    private func apply(_ events: [ClaudeCode.Event]) {
        for event in events {
            guard !turns.isEmpty else { continue }
            let last = turns.count - 1
            switch event {
            case .ready:
                break
            case .start:
                streamed = false
                needBreak = !turns[last].answer.isEmpty
            case .delta(let text):
                if needBreak { turns[last].answer += "\n\n"; needBreak = false }
                turns[last].answer += text
                streamed = true
            case .text(let text):
                // Already shown as it was written.
                if streamed { continue }
                turns[last].answer += (turns[last].answer.isEmpty ? "" : "\n\n") + text
            case .tool(let id, let step):
                if let id { guard seenTools.insert(id).inserted else { continue } }
                else if turns[last].steps.last == step { continue }
                turns[last].steps.append(step)
            case .done:
                turns[last].done = true
                running = false
            case .failed(let why):
                // The program says its trouble twice, as words and as the
                // result: once is enough.
                if turns[last].answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    == why.trimmingCharacters(in: .whitespacesAndNewlines) { turns[last].answer = "" }
                finish(failing: Self.explain(why))
            }
        }
    }

    /// The turn in hand ends badly.
    private func finish(failing why: String) {
        guard let last = turns.indices.last else { running = false; return }
        if turns[last].failed == nil { turns[last].failed = why }
        turns[last].done = true
        running = false
    }

    /// Its own words, with what to do about the ones people meet.
    nonisolated static func explain(_ why: String) -> String {
        let lower = why.lowercased()
        if lower.contains("not logged in") || lower.contains("/login") {
            return "Claude Code isn't signed in. Run claude once in Terminal, sign in, and try again."
        }
        return why
    }

    private func ended(run: Process, code: Int32) {
        // Only the run that is current: one let go has been dealt with.
        guard process === run else { return }
        process = nil
        input = nil
        cleanUp()
        if running { finish(failing: code == 0 ? "Claude Code ended." : "Claude Code stopped (\(code)).") }
        running = false
    }
}
