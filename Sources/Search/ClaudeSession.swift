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
// The browser side is not here: it is AgentControl, which keeps it to tabs
// it opened, away from passwords and the rest (see its notes). Your press of
// Send is the consent: the run started here is let in without a second
// question, by a pass made for this run alone and only while a message of
// yours is being answered (PanelRun). Nothing to switch on first.

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
        /// The tabs it left to you when it finished.
        var left: [Tab.ID] = []
        /// Results it laid out as cards (create_artifact).
        var artifacts: [Artifact] = []
        /// What you attached to your message, as its chips said it.
        var attached: [String] = []
    }

    /// Why it can't start, as the panel says it.
    enum Problem: Equatable {
        case notInstalled
        case notSigned
        case noServer
    }

    @Published private(set) var turns: [Turn] = []
    /// Named with "@" for the next message, and that one only (Mentions).
    @Published var mentions: [Mention] = []

    func mention(_ new: Mention) {
        guard mentions.count < Mentions.most, !mentions.contains(where: { $0.id == new.id }) else { return }
        mentions.append(new)
    }

    /// A finished exchange put in by the bench, to look at the panel in use
    /// without Claude Code. A test run only.
    func seed(question: String, answer: String, steps: [String], failed: String? = nil) {
        guard Store.testing else { return }
        var turn = Turn(question: question)
        turn.answer = answer
        turn.steps = steps
        turn.done = true
        turn.failed = failed
        turns.append(turn)
    }
    @Published private(set) var running = false
    @Published private(set) var problem: Problem?
    @Published var draft = ""

    private let executable: URL?
    private let verify: (URL) -> Bool
    private let tool: URL?
    private let world: String?
    private let options: () -> ClaudeCode.Options
    /// The window the panel is in: where the run works.
    private let window: () -> Browser?
    private let playbooks: () -> [Playbook]
    /// Writes a task's record; true when it adds to one already written.
    private let keep: @MainActor (TaskRecord, Bool) -> Void
    /// What lets this run, and only this one, in without a question
    /// (PanelRun); new with each run.
    private var pass = ""

    private var process: Process?
    private var input: FileHandle?
    private var folder: URL?
    private var pending = Data()
    /// Which run's words are heard: a new one with each start, and none
    /// once Stop has let a run go.
    private var generation = 0
    /// Words of the message in progress arrived as they were written, so the
    /// finished message repeating them is not shown twice.
    private var streamed = false
    /// Words of the answer are arriving, with no tool since (see `step`).
    @Published private var writing = false
    /// The next words open a new paragraph.
    private var needBreak = false
    /// The words of the message in progress, and of the one before it in
    /// this turn: a model that answers, uses a tool (disconnect, often) and
    /// then gives the very same answer again is shown saying it once.
    private var current = ""
    private var previous = ""
    /// Tools already shown for this turn, and where in its steps: told as
    /// they begin and again in the finished message, which may say more (the
    /// site it opens), so the step is said again in place, not added.
    private var seenTools: [String: Int] = [:]
    /// A line longer than this is not the program speaking: it is ended.
    private static let longest = 8 << 20

    init(executable: URL? = nil,
         verify: @escaping (URL) -> Bool = ClaudeCode.signedByAnthropic,
         tool: URL? = nil,
         world: String? = Store.world,
         options: @escaping () -> ClaudeCode.Options = { ClaudeCode.Options() },
         window: @escaping () -> Browser? = { nil },
         playbooks: @escaping () -> [Playbook] = { Playbooks.all() },
         keep: @escaping @MainActor (TaskRecord, Bool) -> Void = { TaskLedger.save($0, amending: $1) }) {
        self.executable = executable
        self.verify = verify
        self.tool = tool
        self.world = world
        self.options = options
        self.window = window
        self.playbooks = playbooks
        self.keep = keep
        // Quitting is Stop too: the run's folder goes with it, rather than
        // being left in the temporary folder for good.
        quitting = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    private var quitting: NSObjectProtocol?

    // MARK: - sending

    func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        // A playbook your message calls goes in with this Send (Playbooks).
        // Any other leading "/" is said to be your words: Claude Code reads a
        // message that begins with one as a command of its own.
        let called = Playbooks.called(by: text, among: text.hasPrefix("/") ? playbooks() : [])
        let words = called.map { Playbooks.message($0.book, words: $0.words) }
            ?? (text.hasPrefix("/") ? "My message: " + text : text)
        if process == nil, !start() { return }
        problem = nil
        draft = ""
        let named = mentions
        mentions = []
        var turn = Turn(question: text)
        turn.attached = (called.map { ["Playbook: \($0.book.name)" + ($0.book.builtIn ? "" : " (yours)")] } ?? []) + named.map(\.label)
        turns.append(turn)
        record = TaskRecord(prompt: AgentRules.scrubbed(text), model: options().model)
        recorded = false
        seenTools = [:]
        streamed = false
        writing = false
        needBreak = false
        current = ""
        previous = ""
        running = true
        // This Send is the consent for what the run does to answer it.
        AgentControl.shared.panelArm(pass: pass, true)
        guard !named.isEmpty else { return write(words) }
        // What was named is read now, once. Stopped meanwhile, nothing goes.
        let mine = generation
        Task { @MainActor [weak self] in
            let tabs = self?.browser?.tabs ?? []
            let attached = await Mentions.gather(named, among: tabs)
            guard let self, self.generation == mine, self.running else { return }
            self.write(Mentions.message(words, with: attached))
        }
    }

    private func write(_ text: String) {
        do {
            try input?.write(contentsOf: ClaudeCode.message(text))
        } catch {
            finish(failing: "Couldn't reach Claude Code. Try again.")
            stop()
        }
    }

    /// A conversation from the start: the run ended, what was said forgotten.
    func newChat() {
        stop()
        record = nil
        turns = []
        problem = nil
        draft = ""
        mentions = []
    }

    // MARK: - the ledger

    /// What the turn in hand has done (TaskLedger). Written when it ends, and
    /// again for what arrives after: its tabs may be handed over later.
    private var record: TaskRecord?
    private var recorded = false

    private func noted(_ change: (inout TaskRecord) -> Void) {
        guard var now = record else { return }
        change(&now)
        guard now != record else { return }
        record = now
        if recorded { keep(now, true) }
    }

    /// A site one of its tabs went to (AgentControl).
    func visited(_ host: String) { noted { $0.visited(host) } }

    /// A question held for you, and how it was answered (AgentControl).
    func asked(reason: String, what: String, answer: String) {
        noted { $0.asked(reason: reason, what: AgentRules.scrubbed(what), answer: answer) }
    }

    /// The turn has ended: its record goes to the disk.
    private func conclude(stopped: Bool, failed: Bool) {
        guard !recorded, var now = record else { return }
        now.outcome = TaskRecord.outcome(stopped: stopped, failed: failed, approvals: now.approvals)
        record = now
        recorded = true
        keep(now, false)
    }

    /// A new task seeded from an earlier one: in the box, for you to send.
    func followUp(_ earlier: TaskRecord) {
        newChat()
        draft = earlier.followUp
    }

    /// A card for the turn in hand; false when there is no room or no turn.
    func add(_ artifact: Artifact) -> Bool {
        guard let last = turns.indices.last, turns[last].artifacts.count < 6 else { return false }
        turns[last].artifacts.append(artifact)
        return true
    }

    /// The tabs the turn in hand left to you (AgentControl's hand-over).
    func left(_ tabs: [Tab.ID]) {
        guard let last = turns.indices.last else { return }
        turns[last].left += tabs.filter { !turns[last].left.contains($0) }
        let open = tabs.compactMap { id in browser?.tabs.first { $0.id == id && !$0.shy } }
        noted { record in
            for tab in open {
                guard let url = tab.pageAddress, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                record.left(title: tab.title, url: AgentRules.url(url.absoluteString))
            }
        }
    }

    /// The window the panel is in, where its run works and asks.
    var browser: Browser? { window() }

    /// What it is doing now, while it is: the last thing it said it was at.
    /// Nothing once it is writing its answer, or once it has let go of the
    /// browser: the last step is over, and would otherwise stay up as if not.
    var step: String? {
        guard running, !writing, let last = turns.last?.steps.last, last != ClaudeCode.leaving else { return nil }
        return last
    }

    /// Ends the run, for Stop, for closing the panel, for a window going.
    func stop() {
        let wasRunning = running
        // Stopped mid-turn: the person's Stop, said to AgentControl before
        // the program goes, so its tabs close. Its socket closing alone would
        // read as a task that finished, whose tabs are handed over.
        if wasRunning, !pass.isEmpty { AgentControl.shared.panelStopped(pass: pass) }
        generation += 1
        let live = process
        process = nil
        input = nil
        live?.terminationHandler = nil
        (live?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (live?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if live?.isRunning == true { live?.terminate() }
        cleanUp()
        if wasRunning { finish(failing: Self.stopped) }
        running = false
        disarm()
    }

    /// What a turn ended by Stop says.
    static let stopped = "Stopped."

    /// The turn is over: the run's pass lets nothing in until the next Send.
    private func disarm() {
        AgentControl.shared.panelArm(pass: pass, false)
    }

    // MARK: - starting

    private func start() -> Bool {
        // A program that has gone since it was found (uninstalled, a link
        // left dangling) is not there, rather than "not signed".
        guard let claude = executable ?? ClaudeCode.locate(),
              FileManager.default.isExecutableFile(atPath: claude.path) else { problem = .notInstalled; return false }
        guard verify(claude) else { problem = .notSigned; return false }
        guard let tool = tool ?? ClaudeCode.mcpTool() else { problem = .noServer; return false }

        // A folder for this run alone, to be empty and to go.
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent("cairn-claude-\(UUID().uuidString)", isDirectory: true)
        let pass = PanelRun.newPass()
        do {
            try files.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try ClaudeCode.mcpConfig(tool: tool, world: world, pass: pass).write(to: home.appendingPathComponent("mcp.json"))
        } catch {
            try? files.removeItem(at: home)
            problem = .noServer
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

        generation += 1
        let mine = generation
        fromIt.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.take(data, from: mine) } }
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
        self.pass = pass
        AgentControl.shared.panelStarted(pass: pass, pid: run.processIdentifier, browser: window())
        // A write to a program that has gone fails; it must not raise SIGPIPE.
        _ = fcntl(toIt.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        input = toIt.fileHandleForWriting
        folder = home
        pending = Data()
        return true
    }

    private func cleanUp() {
        AgentControl.shared.panelEnded(pass: pass)
        pass = ""
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
        pending = Data()
    }

    // MARK: - what comes back

    private func take(_ data: Data, from run: Int) {
        // Words already on their way when Stop was pressed, or from a run
        // since let go, belong to no turn: a step added after "Stopped."
        // would say it went on. (A run that ended by itself is still heard
        // out: its last words may come after the news of its end.)
        guard run == generation else { return }
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
                dropRepeat(last)
                streamed = false
                needBreak = !turns[last].answer.isEmpty
            case .delta(let text):
                if needBreak { turns[last].answer += "\n\n"; needBreak = false }
                turns[last].answer += text
                current += text
                streamed = true
                writing = true
            case .text(let text):
                // Already shown as it was written.
                if streamed { continue }
                turns[last].answer += (turns[last].answer.isEmpty ? "" : "\n\n") + text
                current += text
                writing = true
            case .tool(let id, let step):
                writing = false
                if let id {
                    if let at = seenTools[id] {
                        if turns[last].steps.indices.contains(at) { turns[last].steps[at] = step }
                        continue
                    }
                    seenTools[id] = turns[last].steps.count
                } else if turns[last].steps.last == step { continue }
                turns[last].steps.append(step)
            case .done:
                dropRepeat(last)
                turns[last].done = true
                running = false
                disarm()
                conclude(stopped: false, failed: false)
            case .failed(let why):
                // The program says its trouble twice, as words and as the
                // result: once is enough.
                if turns[last].answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    == why.trimmingCharacters(in: .whitespacesAndNewlines) { turns[last].answer = "" }
                finish(failing: Self.explain(why))
            }
        }
    }

    /// The message just ended, taken back out of the answer when it said
    /// word for word what the one before it did (seen with a real Claude
    /// Code: the answer, a call to disconnect, then the answer again).
    private func dropRepeat(_ last: Int) {
        defer {
            if !current.isEmpty { previous = current }
            current = ""
        }
        let said = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, said == previous.trimmingCharacters(in: .whitespacesAndNewlines),
              turns[last].answer.hasSuffix(current) else { return }
        turns[last].answer.removeLast(current.count)
        while turns[last].answer.last?.isNewline == true { turns[last].answer.removeLast() }
    }

    /// The turn in hand ends badly.
    private func finish(failing why: String) {
        guard let last = turns.indices.last else { running = false; return }
        if turns[last].failed == nil { turns[last].failed = why }
        turns[last].done = true
        running = false
        disarm()
        conclude(stopped: why == Self.stopped, failed: true)
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
