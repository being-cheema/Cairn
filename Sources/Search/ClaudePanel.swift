import SwiftUI

// Claude in the side panel (ClaudeSession): a conversation drawn as the rest
// of the browser is — the same ink, muted and faint, the same sizes, hairlines
// and pills, and as plain: text only, nothing to follow, nothing to fetch.
// Nothing to switch on first: your Send is the go-ahead (PanelRun).
//
// What you said sits in a soft bubble on the right, what Claude did as quiet
// lines with a tick each, and what it says as plain text on the left, written
// as it arrives. The box grows with what you type; Return sends, and the
// button beside it is Stop while Claude works.

struct ClaudePanel: View {
    @ObservedObject var session: ClaudeSession
    /// The model it runs (ClaudeCode.models), nil for the person's own default.
    @Binding var model: String?
    let close: () -> Void
    let openSettings: () -> Void
    @FocusState private var typing: Bool
    /// The row of the "@" list the keys are on, and a list put away with esc.
    @State private var picked = 0
    @State private var dismissed: String?
    /// The playbooks, read from their folder each time a "/" begins the box.
    @State private var books: [Playbook] = []
    @State private var showingHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Palette.hairline).frame(height: 1)

            ScrollViewReader { scroller in
                ScrollView(showsIndicators: false) {
                    conversation
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 8)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: session.turns.last?.answer) { _, _ in scrollToEnd(scroller) }
                .onChange(of: session.turns.last?.steps.count) { _, _ in scrollToEnd(scroller) }
                .onChange(of: session.turns.count) { _, _ in scrollToEnd(scroller) }
            }

            if session.canRewind {
                HStack(spacing: 8) {
                    Button { session.rewind(event: NSApp.currentEvent) } label: {
                        Text("Rewind Step")
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Palette.wash, in: Capsule())
                            .background(ClickSpot { session.rewindButton = $0 })
                    }
                    .buttonStyle(.plain)
                    .help(ClaudeSession.rewindWarning)
                    Text("Page only: it can't unsend what was already sent.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 5)
            }
            // Held for the person (AgentGate): said here too, above the box,
            // where it can't scroll away — the card with Approve is at the
            // foot of the page, and a click of yours there is the only answer.
            PanelHeld(claude: session) { waiting in
                if waiting { PanelWaiting(claude: session) }
            }
            composer
        }
        .onAppear { typing = true }
    }

    // MARK: - the top

    private var header: some View {
        HStack(spacing: 8) {
            Ink("sparkles", size: 11)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                PanelHeld(claude: session) { waiting in
                    if waiting {
                        Text("Waiting for you")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.accent)
                            .lineLimit(1)
                            .transition(.opacity)
                    } else if let step = session.step {
                        Text(verbatim: step + "…")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
            }
            Spacer(minLength: 0)
            Door(icon: "clock", help: "Task History") { showingHistory.toggle() }
                .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                    TaskHistory(session: session) { showingHistory = false }
                }
            Door(icon: "square.and.pencil", help: "New Chat") { session.newChat() }
                .opacity(session.turns.isEmpty && session.problem == nil ? 0.35 : 1)
                .disabled(session.turns.isEmpty && session.problem == nil)
            Door(icon: "xmark", help: "Close") { close() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .animation(.easeOut(duration: 0.15), value: session.step)
    }

    private func scrollToEnd(_ scroller: ScrollViewProxy) {
        scroller.scrollTo("end", anchor: .bottom)
    }

    // MARK: - the conversation

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let problem = session.problem {
                notice(problem)
            }
            if session.turns.isEmpty, session.problem == nil {
                welcome
            }
            ForEach(Array(session.turns.enumerated()), id: \.element.id) { index, turn in
                TurnView(turn: turn, working: session.running && index == session.turns.count - 1, browser: session.browser)
                    .id(turn.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Before the first message: what it is for, and a few ways to begin.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            ArtPicture(name: "chat", size: 112)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Text("What should I do?")
                    .font(Typeface.heading(19, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text("I work in tabs of my own, not signed in to anything. When I finish, they're yours. I never use your saved passwords, and anything that sends, pays or posts waits for your click.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.ideas, id: \.self) { idea in
                    Button {
                        session.draft = idea
                        typing = true
                    } label: {
                        Text(verbatim: idea)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 6)
    }

    static let ideas = [
        "Open a site and tell me what's on it",
        "Search for something and open the best result",
        "Compare a few options and tell me which to pick",
    ]

    private func notice(_ problem: ClaudeSession.Problem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ArtPicture(name: "error", size: 56)
            Text(verbatim: Self.say(problem))
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// A turn you stopped, said as what you did rather than as a fault.
    static let stoppedWords = "You stopped it. Its tabs were closed."

    /// What a task used, rounded: the size of it is what matters.
    static func tokens(_ count: Int) -> String {
        if count < 1000 { return "Used under 1k tokens" }
        if count < 1_000_000 { return "Used about \((count + 500) / 1000)k tokens" }
        let tenths = (count + 50_000) / 100_000
        return "Used about \(tenths / 10).\(tenths % 10)M tokens"
    }

    static func earlier(_ count: Int) -> String {
        count == 1 ? "1 earlier step" : "\(count) earlier steps"
    }

    static func say(_ problem: ClaudeSession.Problem) -> String {
        switch problem {
        case .notInstalled:
            return "Claude Code isn't on this Mac. Install it, run claude once in Terminal to sign in, and come back."
        case .notSigned:
            return "The claude program on this Mac isn't signed by Anthropic, so it isn't started."
        case .noServer:
            return "This copy of \(Brand.name) has no cairn-mcp to give Claude Code, so there is nothing for it to use."
        case .notSent(let why):
            return why
        }
    }

    // MARK: - what you type

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !choices.isEmpty { MentionList(choices: choices, picked: min(picked, choices.count - 1)) { take($0) } }
            if !plays.isEmpty { PlaybookList(books: plays, picked: min(picked, plays.count - 1)) { take($0) } }
            if !session.mentions.isEmpty { chips }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("", text: $session.draft, prompt: Text("Ask Claude… @ tab, / playbook").foregroundStyle(Palette.muted), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1...6)
                    .focused($typing)
                    .onSubmit {
                        if !choices.isEmpty { take(choices[min(picked, choices.count - 1)]) }
                        else if !plays.isEmpty { take(plays[min(picked, plays.count - 1)]) }
                        else { session.submit() }
                    }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.escape) {
                        guard !choices.isEmpty || !plays.isEmpty else { return .ignored }
                        dismissed = session.draft
                        return .handled
                    }
                    .onChange(of: session.draft) { before, now in
                        picked = 0
                        if now.hasPrefix("/"), !before.hasPrefix("/") || books.isEmpty { books = Playbooks.all() }
                    }
                    .disabled(session.running)
                    .padding(.vertical, 5)
                send
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))

            HStack(spacing: 8) {
                modelMenu
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Palette.wash, in: Capsule())
                Text("Claude can make mistakes. Check important details.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Answered by the Claude Code program on this Mac")
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: - "@"

    /// What the "@" being typed may become: your selection, then tabs.
    private var choices: [MentionChoice] {
        guard !session.running, session.draft != dismissed, session.mentions.count < Mentions.most,
              let query = Mentions.query(in: session.draft), let browser = session.browser else { return [] }
        let front = browser.active
        var out: [MentionChoice] = []
        if let front, Mentions.mayName(front), query.isEmpty || "selected text".hasPrefix(query.lowercased()) {
            out.append(.selection(front))
        }
        if ReadingMemory.shared.on, "memory".hasPrefix(query.lowercased()), !session.mentions.contains(.memory) {
            out.append(.memory)
        }
        out += Mentions.matching(query, among: browser.tabs, front: front).map { .tab($0, front: $0.id == front?.id) }
        return out
    }

    /// What the "/" being typed may become.
    private var plays: [Playbook] {
        guard !session.running, session.draft != dismissed, let query = Playbooks.query(in: session.draft) else { return [] }
        // A name typed in full is no longer being looked for: Return sends it.
        if books.contains(where: { $0.name == query.lowercased() }) { return [] }
        return Playbooks.matching(query, among: books)
    }

    /// Writes its name in the box. Nothing is sent: that is your Return.
    private func take(_ book: Playbook) {
        session.draft = "/" + book.name + " "
        typing = true
    }

    private func move(_ by: Int) -> KeyPress.Result {
        let count = choices.isEmpty ? plays.count : choices.count
        guard count > 0 else { return .ignored }
        picked = (min(picked, count - 1) + by + count) % count
        return .handled
    }

    private func take(_ choice: MentionChoice) {
        session.draft = Mentions.removingQuery(from: session.draft)
        typing = true
        switch choice {
        case .memory:
            session.mention(.memory)
        case .tab(let tab, _):
            session.mention(.tab(tab.id, label: Mentions.label(tab), page: Mentions.page(tab)))
        case .selection(let tab):
            Task { @MainActor in
                if let text = await Mentions.selection(in: tab) {
                    session.mention(.selection(text, from: Mentions.label(tab)))
                } else {
                    session.browser?.announce("Nothing is selected on that page")
                }
            }
        }
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(session.mentions) { mention in
                        HStack(spacing: 4) {
                            Text(verbatim: mention.label).font(.system(size: 11.5)).foregroundStyle(Palette.ink).lineLimit(1)
                            Button { session.mentions.removeAll { $0.id == mention.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.muted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(mention.label)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Palette.wash, in: Capsule())
                    }
                }
            }
            // Said before it goes: what leaves this Mac with the message.
            Text(session.mentions.contains(.memory)
                 ? "The attached text goes to Claude with this message, once. @memory adds saved text from up to \(ReadingMemory.mostAttached) pages that match it."
                 : "The visible text goes to Claude with this message, once.")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    /// Which model, from the few Claude Code takes by name. A change starts a
    /// new chat: a running Claude Code can't switch, and a new one wouldn't
    /// remember what was said.
    private var modelMenu: some View {
        let shown = ClaudeCode.models.first { $0.alias == model }?.name ?? "Default"
        return Menu {
            Button { choose(nil) } label: { Label("Default", systemImage: model == nil ? "checkmark" : "") }
            ForEach(ClaudeCode.models, id: \.alias) { entry in
                Button { choose(entry.alias) } label: { Label(entry.name, systemImage: model == entry.alias ? "checkmark" : "") }
            }
            if !session.turns.isEmpty {
                Divider()
                Text("Changing it starts a new chat")
            }
        } label: {
            // One run of text: a menu's own button drops a drawn glyph.
            Text(verbatim: "Model: \(shown) ▾")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which Claude model answers")
    }

    private func choose(_ alias: String?) {
        guard alias != model else { return }
        model = alias
        if !session.turns.isEmpty || session.running { session.newChat() }
    }

    /// Send, or Stop while it works.
    private var send: some View {
        let busy = session.running
        let ready = !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            if busy { session.stop() } else { session.submit() }
        } label: {
            Image(systemName: busy ? "stop.fill" : "arrow.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.ground)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.ink.opacity(busy || ready ? 1 : 0.25)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!busy && !ready)
        .help(busy ? "Stop" : "Send   ⏎")
    }

    // MARK: - one exchange

    private struct TurnView: View {
        let turn: ClaudeSession.Turn
        let working: Bool
        let browser: Browser?

        /// Only the latest few steps in full, the rest counted.
        private static let shown = 4

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                if !turn.attached.isEmpty {
                    HStack(spacing: 0) {
                        Spacer(minLength: 36)
                        Text(verbatim: turn.attached.joined(separator: "  "))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                    }
                }
                HStack(spacing: 0) {
                    Spacer(minLength: 36)
                    Text(verbatim: turn.question)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if !turn.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        if turn.steps.count > Self.shown {
                            Text(verbatim: ClaudePanel.earlier(turn.steps.count - Self.shown))
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.muted)
                        }
                        let tail = Array(turn.steps.suffix(Self.shown).enumerated())
                        ForEach(tail, id: \.offset) { index, step in
                            let live = working && index == tail.count - 1 && turn.answer.isEmpty
                            HStack(spacing: 6) {
                                // One column for the tick and the spinner,
                                // so the words line up either way.
                                Group {
                                    if live {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Ink("checkmark", size: 13).font(.system(size: 8.5, weight: .semibold))
                                    }
                                }
                                .frame(width: 12, height: 12)
                                Text(verbatim: step)
                                    .font(.system(size: 11.5))
                            }
                            .foregroundStyle(live ? Palette.ink : Palette.muted)
                        }
                    }
                }

                if !turn.scouts.isEmpty {
                    ScoutPills(pages: turn.scouts, working: working)
                }

                if let tokens = turn.tokens, turn.done {
                    Text(verbatim: ClaudePanel.tokens(tokens))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                        .help("Every kind of token the task used, as Claude Code counted it. Each page read is sent again with every later step.")
                }

                ForEach(turn.artifacts) { artifact in
                    ArtifactCard(artifact: artifact, browser: browser)
                }

                if let browser, !turn.left.isEmpty || !turn.answer.isEmpty {
                    LeftTabs(browser: browser, ids: turn.left, named: PanelProse.tabsNamed(in: turn.answer))
                }

                if turn.answer.isEmpty, turn.failed == nil, working, turn.steps.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                        Text("Thinking").font(.system(size: 11.5))
                    }
                    .foregroundStyle(Palette.muted)
                }

                // Set as text, with nothing in it to follow or fetch (PanelProse).
                if !turn.answer.isEmpty {
                    ProseView(text: turn.answer)
                }

                if let failed = turn.failed {
                    // Your Stop is not a fault: said as what you did.
                    let stopped = failed == ClaudeSession.stopped
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Ink(stopped ? "stop.circle" : "exclamationmark.triangle", size: 13).font(.system(size: 10, weight: .medium))
                        Text(verbatim: stopped ? ClaudePanel.stoppedWords : failed).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Palette.muted)
                    .padding(8)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}

/// A pill to each page a batch_read is on: its site, and how far it got. The
/// site's name only, in a host's letters (ClaudeCode.site).
private struct ScoutPills: View {
    let pages: [ScoutProgress]
    let working: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pages) { page in
                    HStack(spacing: 5) {
                        Group {
                            if working, page.state == .waiting || page.state == .loading {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: page.state == .read ? "checkmark" : "xmark")
                                    .font(.system(size: 8.5, weight: .semibold))
                            }
                        }
                        .frame(width: 11, height: 11)
                        Text(verbatim: page.host).font(.system(size: 11)).lineLimit(1)
                    }
                    .foregroundStyle(page.state == .read ? Palette.ink : Palette.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Palette.wash, in: Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(page.host), \(page.said(working: working))")
                }
            }
        }
    }
}

/// One row of the "@" list.
enum MentionChoice: Identifiable {
    case selection(Tab)
    case memory
    case tab(Tab, front: Bool)

    var id: String {
        switch self {
        case .selection: return "selection"
        case .memory: return "memory"
        case .tab(let tab, _): return "\(tab.id)"
        }
    }
}

private struct MentionList: View {
    let choices: [MentionChoice]
    let picked: Int
    let take: (MentionChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                Button { take(choice) } label: {
                    HStack(spacing: 7) {
                        switch choice {
                        case .memory:
                            Text("Reading Memory").font(.system(size: 12)).foregroundStyle(Palette.ink)
                            Spacer(minLength: 0)
                            Text("@memory").font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                        case .selection:
                            Text("Selected Text").font(.system(size: 12)).foregroundStyle(Palette.ink)
                            Spacer(minLength: 0)
                        case .tab(let tab, let front):
                            Mark(icon: tab.icon, letter: tab.monogram, size: 13)
                            Text(verbatim: Mentions.label(tab)).font(.system(size: 12)).foregroundStyle(Palette.ink).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(verbatim: front ? "Current Tab" : tab.pageAddress?.host() ?? "")
                                .font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(index == picked ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == picked ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// The tabs a finished task left open, each a pill that goes to it. Closed
/// ones drop out.
struct LeftTabs: View {
    @ObservedObject var browser: Browser
    let ids: [Tab.ID]
    /// Titles the answer points at (PanelProse.tabsNamed).
    var named: [String] = []

    /// The tabs left to you, then any others the answer names that are open
    /// here. Never a private one.
    static func pills(ids: [Tab.ID], named: [String], among tabs: [Tab]) -> [Tab] {
        var out = ids.compactMap { id in tabs.first { $0.id == id } }
        // A title already shown is the one meant: yours of the same name
        // beside the one it left would be two pills nobody can tell apart.
        for title in named where !out.contains(where: { $0.title == title }) {
            if let tab = tabs.first(where: { !$0.shy && $0.title == title }) {
                out.append(tab)
            }
        }
        return out
    }

    var body: some View {
        let open = Self.pills(ids: ids, named: named, among: browser.tabs)
        if !open.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(open) { tab in LeftTab(tab: tab) { browser.select(tab) } }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private struct LeftTab: View {
        @ObservedObject var tab: Tab
        let go: () -> Void

        var body: some View {
            Button(action: go) {
                HStack(spacing: 6) {
                    Mark(icon: tab.icon, letter: tab.monogram, size: 14)
                    // The page's own title: words to show, nothing more.
                    Text(verbatim: tab.title.isEmpty ? "Tab" : tab.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .frame(maxWidth: 150)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Palette.wash, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Go to this tab")
        }
    }
}

/// Whether the panel's own run is held for the person (AgentGate) in this
/// window: the agent connected is the panel's, and something waits for
/// Approve. Read from AgentControl, which alone answers it.
struct PanelHeld<Content: View>: View {
    @ObservedObject var claude: ClaudeSession
    @ObservedObject private var agents = AgentControl.shared
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        if let session = agents.session {
            Watch(session: session, browser: claude.browser, content: content)
        } else {
            content(false)
        }
    }

    private struct Watch: View {
        @ObservedObject var session: AgentSession
        let browser: Browser?
        let content: (Bool) -> Content

        var body: some View {
            content(PanelHeld<Content>.waiting(panel: session.panel, held: session.held != nil,
                                               here: browser != nil && session.browser === browser))
        }
    }

    /// The panel says it waits only for its own run, held, in its window.
    static func waiting(panel: Bool, held: Bool, here: Bool) -> Bool { panel && held && here }
}

/// Above the box while the run is held: that it waits for you, for what,
/// and where to answer. No Approve here: the card's buttons are the only
/// ones, pressed only by a click of yours on them (AgentRules.isClick).
struct PanelWaiting: View {
    @ObservedObject var claude: ClaudeSession
    @ObservedObject private var agents = AgentControl.shared

    var body: some View {
        if let session = agents.session, let held = session.held {
            HStack(alignment: .top, spacing: 8) {
                Ink("hand.raised", size: 13)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paused: waiting for you")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(verbatim: PanelWaiting.say(held.hold))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .transition(.opacity)
        }
    }

    /// In the browser's words: the site for a move to another one, the kind
    /// of thing otherwise — never the page's words, which the card quotes.
    static func say(_ hold: AgentGate.Hold) -> String {
        let answer = " Approve or Don't Approve on the card at the foot of the page."
        switch hold.reason {
        case .leave:
            let careful = hold.warning == nil ? "" : " The card has a warning about the address."
            return "Claude wants to go to \(hold.site ?? "another site"), a site this task hasn't used yet." + careful + answer
        case .pay: return "Claude wants to pay for something." + answer
        case .send: return "Claude wants to send something." + answer
        case .signIn:
            return "Sign in on \(hold.site ?? "the page") yourself, then press Resume on the card at the foot of the page."
        case .submit: return "Claude wants to submit a form." + answer
        case .flow: return "Claude wants to move text it read on one site to another. The card names the site; it is a guess from matching words." + answer
        }
    }
}

/// The button for it at the right of the row of buttons beside the address.
/// It lights while the panel is up; another press puts it away.
struct ClaudeDoor: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if !browser.isPopup {
            Door(icon: "sparkles",
                 on: browser.sidePanelShown && browser.sidePanel == .claude,
                 help: "Claude   ⌥⌘K") { browser.toggleClaudePanel() }
        }
    }
}
