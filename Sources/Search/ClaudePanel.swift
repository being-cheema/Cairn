import SwiftUI

// Claude in the side panel (ClaudeSession): a conversation drawn as the rest
// of the browser is — the same ink, muted and faint, the same sizes, hairlines
// and pills, and as plain: text only, nothing to follow, nothing to fetch.
// It still needs "Let coding agents use Search" (Settings › About › Developer),
// which is the person's to allow.
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

            composer
        }
        .onAppear { typing = true }
    }

    // MARK: - the top

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                if let step = session.step {
                    Text(verbatim: step + "…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .transition(.opacity)
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
                Text("I work in a clean browser of my own: not signed in to anything, and gone when we're done. You are asked before I start.")
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
            Text(verbatim: Self.say(problem))
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if problem == .agentsOff {
                Pill("Open Settings", filled: true) { openSettings() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    static func say(_ problem: ClaudeSession.Problem) -> String {
        switch problem {
        case .notInstalled:
            return "Claude Code isn't on this Mac. Install it, run claude once in Terminal to sign in, and come back."
        case .notSigned:
            return "The claude program on this Mac isn't signed by Anthropic, so it isn't started."
        case .noScript:
            return "This copy of \(Brand.name) has no search-mcp to give Claude Code, so there is nothing for it to use."
        case .agentsOff:
            return "Turn on Settings › About › Developer › Let coding agents use Search first. Claude then asks you, in this window, before it starts."
        }
    }

    // MARK: - what you type

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("", text: $session.draft, prompt: Text("Ask Claude…").foregroundStyle(Palette.faint), axis: .vertical)
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

            HStack(spacing: 6) {
                modelMenu
                Text("· Claude Code on this Mac · may be wrong")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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
            HStack(spacing: 3) {
                Text(verbatim: shown)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .semibold))
            }
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
                            Text("\(turn.steps.count - Self.shown) earlier steps")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.faint)
                        }
                        let tail = Array(turn.steps.suffix(Self.shown).enumerated())
                        ForEach(tail, id: \.offset) { index, step in
                            let live = working && index == tail.count - 1 && turn.answer.isEmpty
                            HStack(spacing: 6) {
                                if live {
                                    ProgressView().controlSize(.mini).frame(width: 9, height: 9)
                                } else {
                                    Image(systemName: "checkmark").font(.system(size: 8.5, weight: .semibold))
                                }
                                Text(verbatim: step)
                                    .font(.system(size: 11.5))
                            }
                            .foregroundStyle(live ? Palette.muted : Palette.faint)
                        }
                    }
                }

                if turn.answer.isEmpty, turn.failed == nil, working, turn.steps.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).frame(width: 9, height: 9)
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
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .medium))
                        Text(verbatim: failed).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Palette.muted)
                    .padding(8)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
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
