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
                        Text("Waiting for your approval")
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
                TurnView(turn: turn, working: session.running && index == session.turns.count - 1)
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

    static func earlier(_ count: Int) -> String {
        count == 1 ? "1 earlier step" : "\(count) earlier steps"
    }

    static func say(_ problem: ClaudeSession.Problem) -> String {
        switch problem {
        case .notInstalled:
            return "Claude Code isn't on this Mac. Install it, run claude once in Terminal to sign in, and come back."
        case .notSigned:
            return "The claude program on this Mac isn't signed by Anthropic, so it isn't started."
        case .noScript:
            return "This copy of \(Brand.name) has no search-mcp to give Claude Code, so there is nothing for it to use."
        }
    }

    // MARK: - what you type

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("", text: $session.draft, prompt: Text("Ask Claude…").foregroundStyle(Palette.muted), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1...6)
                    .focused($typing)
                    .onSubmit { session.submit() }
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

        /// Only the latest few steps in full, the rest counted.
        private static let shown = 4

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
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

                if turn.answer.isEmpty, turn.failed == nil, working, turn.steps.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                        Text("Thinking").font(.system(size: 11.5))
                    }
                    .foregroundStyle(Palette.muted)
                }

                // As written, and never as markdown: no link to follow, no
                // picture to fetch.
                if !turn.answer.isEmpty {
                    Text(verbatim: turn.answer)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            return "Claude wants to go to \(hold.site ?? "another site"), a site this task hasn't used yet." + answer
        case .pay: return "Claude wants to pay for something." + answer
        case .send: return "Claude wants to send something." + answer
        case .signIn: return "Claude wants to sign in somewhere." + answer
        case .submit: return "Claude wants to submit a form." + answer
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
