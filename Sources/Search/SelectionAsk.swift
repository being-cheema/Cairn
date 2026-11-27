import AppKit
import SwiftUI
import WebKit

// Ask about a selection (⌘E): a small popover beside the words you selected,
// with a box for your question. Press ⌘E and nothing is sent: the popover
// only opens. Pressing Ask in it (your click) sends the selection, and the
// paragraph around it, to your own Claude as the panel does for an "@"
// mention (Mentions): fenced as the website's words, the selection read as
// you saw it (hidden and unreadable text left out), never from a private
// tab, a site you blocked, or a password, card or code field, none of which
// a selection reaches. "Continue in Panel" puts the same in the panel's box
// instead, for you to send there.
//
// The answer is Claude's from those words only so far as it is asked to be:
// the message says so, and it is not a limit the browser can enforce on the
// panel's run, which has the panel's usual tools.

enum SelectionAsk {
    /// What goes with your question: asked to stay inside what was attached.
    static func message(_ typed: String) -> String {
        let question = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = question.isEmpty ? "Explain this." : question
        return "About the selected text attached to this message (and the paragraph around it): \(ask)\n\n"
            + "Answer only from that text. Don't browse or use any tools."
    }

    /// A line of the selection for the popover's heading.
    static func excerpt(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > 140 ? String(line.prefix(140)) + "…" : line
    }

    /// Where the selection is on screen and the block of text around it, as
    /// the page shows it. Read only, in the browser's own world.
    static let script = """
    (function () {
      var sel = window.getSelection();
      if (!sel || !sel.rangeCount) return JSON.stringify({});
      var r = sel.getRangeAt(0).getBoundingClientRect();
      var node = sel.getRangeAt(0).commonAncestorContainer;
      var el = node.nodeType === 1 ? node : node.parentElement;
      while (el && el.parentElement && /^inline/.test(getComputedStyle(el).display)) el = el.parentElement;
      var block = el && el.innerText ? el.innerText.replace(/\\s+/g, ' ').trim().slice(0, 1500) : '';
      return JSON.stringify({ rect: [r.left, r.top, r.width, r.height], context: block });
    })()
    """
}

@MainActor
final class SelectionAskCard: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    static let shared = SelectionAskCard()

    func show(over web: WKWebView, rect: NSRect, mentions: [Mention], excerpt: String, browser: Browser) {
        popover?.close()
        let card = NSPopover()
        card.behavior = .transient
        card.delegate = self
        let view = SelectionAskView(claude: browser.claude, mentions: mentions, excerpt: excerpt,
                                    continueInPanel: { [weak self, weak browser] typed in
            guard let browser else { return }
            browser.claude.mentions = mentions
            browser.claude.draft = SelectionAsk.message(typed)
            if !(browser.sidePanelShown && browser.sidePanel == .claude) { browser.toggleClaudePanel() }
            self?.popover?.close()
        })
        card.contentViewController = NSHostingController(rootView: view)
        card.show(relativeTo: rect, of: web, preferredEdge: .maxX)
        popover = card
    }

    func popoverDidClose(_ notification: Notification) { popover = nil }
}

private struct SelectionAskView: View {
    @ObservedObject var claude: ClaudeSession
    let mentions: [Mention]
    let excerpt: String
    let continueInPanel: (String) -> Void
    @State private var typed = ""
    @State private var asked = false

    private var answer: String { asked ? (claude.turns.last?.answer ?? "") : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "“\(excerpt)”")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
            TextField("Ask about this…", text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit { ask() }
            if asked {
                ScrollView {
                    Text(verbatim: answer.isEmpty ? (claude.turns.last?.failed ?? "Thinking…") : answer)
                        .font(.system(size: 12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            HStack {
                Button("Continue in Panel") { continueInPanel(typed) }
                Spacer()
                Button("Ask") { ask() }
                    .disabled(claude.running)
                    .keyboardShortcut(.defaultAction)
            }
            Text("Sends the selection and the text around it to your Claude. It is asked to use only those words.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 320)
    }

    private func ask() {
        guard !claude.running else { return }
        claude.mentions = mentions
        claude.draft = SelectionAsk.message(typed)
        claude.submit()
        asked = claude.turns.last?.question == SelectionAsk.message(typed)
    }
}

extension Browser {
    /// Edit › Ask About Selection… (⌘E): opens the card. Only for a page you
    /// could name to Claude (Mentions.mayName), and only with words selected.
    func askAboutSelection() {
        guard let tab = active, Mentions.mayName(tab), let web = tab.built else {
            announce("Select some text on a page first")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let text = await Mentions.selection(in: tab) else {
                self.announce("Select some text on a page first")
                return
            }
            let found: Any? = await withCheckedContinuation { done in
                web.evaluateJavaScript(SelectionAsk.script, in: nil, in: Web.world) { done.resume(returning: try? $0.get()) }
            }
            let info = (found as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let from = tab.pageAddress?.host() ?? "the page"
            var mentions: [Mention] = [.selection(text, from: from)]
            // The paragraph, fenced like the rest, only when it says more than the selection.
            if let context = info["context"] as? String, context.count > text.count + 20 {
                mentions.append(.selection(Quarantine.fence(TypedSecrets.hidden(in: context)), from: "\(from), the paragraph around it"))
            }
            let zoom = web.pageZoom * web.magnification
            let numbers = (info["rect"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            var rect = NSRect(x: web.bounds.midX, y: web.bounds.midY, width: 1, height: 1)
            if numbers.count == 4 {
                let top = numbers[1] * zoom, height = max(numbers[3] * zoom, 1)
                rect = NSRect(x: numbers[0] * zoom, y: web.isFlipped ? top : web.bounds.height - top - height,
                              width: max(numbers[2] * zoom, 1), height: height)
            }
            SelectionAskCard.shared.show(over: web, rect: rect, mentions: mentions, excerpt: SelectionAsk.excerpt(text), browser: self)
        }
    }
}
