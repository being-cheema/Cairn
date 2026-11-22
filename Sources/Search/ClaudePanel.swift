import SwiftUI

// Claude in the side panel (ClaudeSession): a conversation drawn as the rest
// of the browser is — the same ink, muted and faint, the same sizes, hairlines
// and pills, and as plain: text only, nothing to follow, nothing to fetch.
// Off until Settings › About › Developer › Claude in the side panel is on.

struct ClaudePanel: View {
    @ObservedObject var session: ClaudeSession
    let close: () -> Void
    let openSettings: () -> Void
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Text("Claude")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                if session.running {
                    Pill("Stop") { session.stop() }
                }
                Door(icon: "xmark", help: "Close") { close() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            Rectangle().fill(Palette.hairline).frame(height: 1)

            ScrollViewReader { scroller in
                ScrollView(showsIndicators: false) {
                    conversation
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .onChange(of: session.turns.last?.answer) { _, _ in scrollToEnd(scroller) }
                .onChange(of: session.turns.last?.steps.count) { _, _ in scrollToEnd(scroller) }
                .onChange(of: session.turns.count) { _, _ in scrollToEnd(scroller) }
            }

            Rectangle().fill(Palette.hairline).frame(height: 1)
            TextField("", text: $session.draft, prompt: Text("Ask Claude…").foregroundStyle(Palette.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .focused($typing)
                .onSubmit { session.submit() }
                .disabled(session.running)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Text("Claude Code on this Mac · browser tools only · may be wrong")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.faint)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .onAppear { typing = true }
    }

    private func scrollToEnd(_ scroller: ScrollViewProxy) {
        if let last = session.turns.last { scroller.scrollTo(last.id, anchor: .bottom) }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let problem = session.problem {
                notice(problem)
            } else if session.turns.isEmpty {
                Text("Ask Claude to do something in the browser. It works in tabs of its own, and you are asked before it starts.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(session.turns) { turn in
                TurnView(turn: turn).id(turn.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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

    private struct TurnView: View {
        let turn: ClaudeSession.Turn

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: turn.question)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, step in
                    Text(verbatim: step + "…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.faint)
                }
                if turn.answer.isEmpty, turn.failed == nil, !turn.done {
                    Text("…").font(.system(size: 13)).foregroundStyle(Palette.faint)
                }
                // As written, and never as markdown: no link to follow, no
                // picture to fetch.
                if !turn.answer.isEmpty {
                    Text(verbatim: turn.answer)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failed = turn.failed {
                    Text(verbatim: failed)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
