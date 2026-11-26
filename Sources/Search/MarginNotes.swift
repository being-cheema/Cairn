import AppKit
import SwiftUI
import WebKit

// Notes an agent leaves in the margin of a page it is reading with you
// (annotate_page): the part highlighted, the note beside it.
//
// Nothing goes into the page: no element, no style, nothing a site's script
// could see. The highlight and the note are drawn by the app in a view of
// its own over the web view; all the page is asked is where the part is now,
// in Search's own world. The view takes no clicks.
//
// Only on the agent's own tabs, made through the same check as its clicks:
// there is no way to name a tab of yours here. The notes stay with the tab
// when the task hands it to you, live in memory only, and go with it.
//
// A note is words from a model that has been reading web pages, so it is
// shown as plain text, short, under a heading of the browser's saying whose
// note it is.

struct MarginNote: Equatable, Identifiable {
    /// Unique in its tab: also what the part is kept under in the page.
    let id: Int
    let words: String
    /// The part's own words, as they were when noted.
    let quote: String
    /// Whose note: the browser's name for the agent.
    let author: String
    /// The page it is on, without its fragment, secrets taken out.
    let page: String
}

enum MarginNotes {
    static let most = 20
    static let longestNote = 280, longestQuote = 300

    /// A page as a note remembers it.
    static func page(_ url: URL?) -> String {
        var text = url?.absoluteString ?? ""
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        return AgentRules.url(text)
    }

    /// The next note for a tab that has `notes`; nil when it is full or
    /// there is nothing to say.
    static func next(after notes: [MarginNote], words: String, quote: String, author: String, page: String) -> MarginNote? {
        let said = Artifact.line(TypedSecrets.hidden(in: words), longestNote)
        guard notes.count < most, !said.isEmpty else { return nil }
        return MarginNote(id: (notes.map(\.id).max() ?? 0) + 1, words: said,
                          quote: Artifact.line(TypedSecrets.hidden(in: quote), longestQuote),
                          author: Artifact.line(author, 40), page: page)
    }

    /// These notes as Markdown, or nil with none. Neither a note nor the
    /// page's words can become a link or break out of its line.
    static func markdown(_ notes: [MarginNote]) -> String? {
        guard !notes.isEmpty else { return nil }
        func plain(_ text: String) -> String {
            var out = ""
            for character in text {
                if "\\`*_[]<>|#".contains(character) { out.append("\\") }
                out.append(character)
            }
            return out
        }
        var out = "## Margin notes\n"
        for note in notes {
            out += "\n"
            if !note.quote.isEmpty { out += "> \(plain(note.quote))\n\n" }
            out += "\(plain(note.words)) (note from \(plain(note.author)))\n"
        }
        return out
    }

    /// Where each card goes down the margin: level with its part where there
    /// is room, otherwise just under the card above.
    static func stack(tops: [CGFloat], heights: [CGFloat], gap: CGFloat = 6) -> [CGFloat] {
        var out = [CGFloat](repeating: 0, count: min(tops.count, heights.count))
        var floor: CGFloat = gap
        for index in out.indices.sorted(by: { tops[$0] < tops[$1] }) {
            out[index] = max(tops[index], floor)
            floor = out[index] + heights[index] + gap
        }
        return out
    }

    // MARK: - in the page

    /// Keeps the part a note is about, under the note's number: the element
    /// of a read (`index` in the list kept under `key`), or else the
    /// smallest visible part of the page that holds `quote`. Answers with
    /// the part's words. A field gives its name, never what is in it.
    static func anchor(id: Int, key: String, snap: Int?, index: Int?, quote: String) -> String {
        PageScripts.call(#"""
        (function (id, key, snap, i, wanted) {
          function no(code, message) { return JSON.stringify({ error: code, message: message }); }
          function flat(s) { return String(s == null ? '' : s).replace(/\s+/g, ' ').trim(); }
          var el = null;
          if (i !== null) {
            var kept = globalThis[key];
            if (!kept || kept.snap !== snap) return no('stale_element', 'The page has changed since that read_page');
            el = kept.els[i];
            if (!el || !el.isConnected) return no('detached', 'That element is no longer in the page');
            if (!visible(el)) return no('not_visible', 'That element is hidden');
          } else {
            var want = flat(wanted).toLowerCase();
            if (want.length < 3 || !document.body) return no('no_quote', 'Give at least a few words from the page');
            var all = Array.prototype.filter.call(
              document.body.querySelectorAll('p,li,blockquote,td,th,h1,h2,h3,h4,h5,h6,figcaption,caption,dd,dt,pre,div,section,article'),
              function (each) { return flat(each.textContent).toLowerCase().indexOf(want) !== -1; });
            all.sort(function (a, b) { return a.textContent.length - b.textContent.length; });
            el = all.find(function (each) { return visible(each) && flat(each.innerText).toLowerCase().indexOf(want) !== -1; }) || null;
            if (!el) return no('no_quote', 'Those words are not in a visible part of the page');
          }
          var field = /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) || el.isContentEditable;
          var words = field ? (el.isContentEditable ? '' : name(el)) : flat(el.innerText).slice(0, 300);
          (globalThis.__searchNotes || (globalThis.__searchNotes = new Map())).set(id, el);
          return JSON.stringify({ ok: true, quote: words });
        })
        """#, [id, key, snap.map { $0 as Any } ?? NSNull(), index.map { $0 as Any } ?? NSNull(), quote])
    }

    /// Where the parts of these notes are drawn now, in CSS pixels of the
    /// viewport; one gone, hidden or from another document is left out.
    static func places(_ ids: [Int]) -> String {
        PageScripts.call(#"""
        (function (ids) {
          var kept = globalThis.__searchNotes, out = [];
          if (kept) ids.forEach(function (id) {
            var el = kept.get(id);
            if (el && el.isConnected && visible(el)) out.push({ id: id, box: boxOf(el) });
          });
          return JSON.stringify({ ok: true, places: out });
        })
        """#, [ids])
    }
}

extension Tab {
    /// This page's margin notes as Markdown, or nil when it has none: what
    /// anything that copies or saves the page adds.
    var marginNotesMarkdown: String? {
        let here = MarginNotes.page(pageAddress)
        return MarginNotes.markdown(marginNotes.filter { $0.page == here })
    }

    /// Whether the page it is on has notes.
    var hasMarginNotes: Bool {
        guard !marginNotes.isEmpty else { return false }
        let here = MarginNotes.page(pageAddress)
        return marginNotes.contains { $0.page == here }
    }
}

// MARK: - drawn

/// Keeps every noted page's marks where its parts are, following it as it
/// scrolls and lays out. One timer, and only while some tab has notes.
@MainActor
final class MarginPainter: ObservableObject {
    static let shared = MarginPainter()

    /// View › Show Margin Notes. Not kept: on again at the next launch.
    @Published var shown = true { didSet { paint() } }

    private struct Watched { weak var tab: Tab? }
    private var watched: [Watched] = []
    private var timer: Timer?
    static let every: TimeInterval = 0.2

    func watch(_ tab: Tab) {
        if !watched.contains(where: { $0.tab === tab }) { watched.append(Watched(tab: tab)) }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { _ in
                MainActor.assumeIsolated { MarginPainter.shared.paint() }
            }
        }
        paint()
    }

    private func paint() {
        watched.removeAll { $0.tab == nil }
        if watched.isEmpty {
            timer?.invalidate()
            timer = nil
            return
        }
        for tab in watched.compactMap(\.tab) {
            guard let web = tab.built else { continue }
            let here = MarginNotes.page(tab.pageAddress)
            let notes = tab.marginNotes.filter { $0.page == here }
            // A page nobody can see isn't asked anything.
            guard shown, !notes.isEmpty, let window = web.window, window !== PageRoom.shared.window,
                  window.occlusionState.contains(.visible) else {
                if !shown || notes.isEmpty { MarginNotesView.remove(from: web) }
                continue
            }
            web.evaluateJavaScript(MarginNotes.places(notes.map(\.id)), in: nil, in: Web.world) { [weak self, weak web] result in
                guard let self, let web, self.shown, case .success(let value) = result, let text = value as? String,
                      let out = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
                let zoom = web.pageZoom * web.magnification
                var boxes: [Int: CGRect] = [:]
                for each in out["places"] as? [[String: Any]] ?? [] {
                    let numbers = (each["box"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
                    if let id = each["id"] as? Int, let numbers, let box = AgentOverlayView.place(numbers, zoom: zoom) {
                        boxes[id] = box
                    }
                }
                MarginNotesView.over(web).draw(notes.compactMap { note in boxes[note.id].map { (note, $0) } })
            }
        }
    }
}

/// The highlights and the margin's cards, over one page.
final class MarginNotesView: NSView {
    static let cardWidth: CGFloat = 210

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// What is drawn now, for the tests.
    private(set) var drawn: [(note: MarginNote, box: CGRect)] = []

    static func over(_ web: WKWebView) -> MarginNotesView {
        if let there = web.subviews.lazy.compactMap({ $0 as? MarginNotesView }).first { return there }
        let made = MarginNotesView(frame: web.bounds)
        made.autoresizingMask = [.width, .height]
        // Under the agent's hand and its question's outline.
        if let hand = web.subviews.first(where: { $0 is AgentOverlayView }) {
            web.addSubview(made, positioned: .below, relativeTo: hand)
        } else {
            web.addSubview(made)
        }
        return made
    }

    static func remove(from web: WKWebView) {
        web.subviews.compactMap { $0 as? MarginNotesView }.forEach { $0.removeFromSuperview() }
    }

    func draw(_ marks: [(MarginNote, CGRect)]) {
        let new = marks.map { (note: $0.0, box: $0.1) }
        guard new.count != drawn.count || zip(new, drawn).contains(where: { $0.note != $1.note || $0.box != $1.box }) else { return }
        drawn = new
        subviews.forEach { $0.removeFromSuperview() }
        let inView = new.filter { $0.box.maxY > 0 && $0.box.minY < bounds.height }
        for mark in inView {
            let highlight = NSView(frame: mark.box.insetBy(dx: -3, dy: -2))
            highlight.wantsLayer = true
            effectiveAppearance.performAsCurrentDrawingAppearance {
                highlight.layer?.backgroundColor = NSColor(Palette.accent).withAlphaComponent(0.14).cgColor
                highlight.layer?.borderColor = NSColor(Palette.accent).withAlphaComponent(0.55).cgColor
            }
            highlight.layer?.borderWidth = 1
            highlight.layer?.cornerRadius = 4
            addSubview(highlight)
        }
        let cards = inView.map { card($0.note) }
        let tops = MarginNotes.stack(tops: inView.map(\.box.minY), heights: cards.map(\.frame.height))
        for (card, top) in zip(cards, tops) {
            card.setFrameOrigin(NSPoint(x: max(bounds.width - Self.cardWidth - 14, 0), y: top))
            addSubview(card)
        }
    }

    private func card(_ note: MarginNote) -> NSView {
        let inner = Self.cardWidth - 18
        func label(_ text: String, _ font: NSFont, _ colour: NSColor, lines: Int) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = font
            field.textColor = colour
            field.isSelectable = false
            field.maximumNumberOfLines = lines
            field.preferredMaxLayoutWidth = inner
            let size = field.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude))
            field.setFrameSize(NSSize(width: inner, height: ceil(size.height)))
            return field
        }
        let from = label("Note from \(note.author)", .systemFont(ofSize: 10, weight: .semibold), Palette.NS.ink.withAlphaComponent(0.55), lines: 1)
        let words = label(note.words, .systemFont(ofSize: 11.5), Palette.NS.ink, lines: 8)
        from.setFrameOrigin(NSPoint(x: 9, y: 7))
        words.setFrameOrigin(NSPoint(x: 9, y: 9 + from.frame.height))
        let card = Flipped(frame: NSRect(x: 0, y: 0, width: Self.cardWidth, height: words.frame.maxY + 8))
        card.wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = Palette.NS.ground.withAlphaComponent(0.97).cgColor
            card.layer?.borderColor = Palette.NS.ink.withAlphaComponent(0.14).cgColor
        }
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 8
        card.addSubview(from)
        card.addSubview(words)
        return card
    }

    private final class Flipped: NSView {
        override var isFlipped: Bool { true }
    }
}

/// View › Show Margin Notes.
struct MarginNotesMenuItem: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var painter = MarginPainter.shared

    var body: some View {
        Toggle("Show Margin Notes", isOn: Binding(get: { painter.shown }, set: { painter.shown = $0 }))
            .shortcut("view.marginNotes")
    }
}

/// In the address line, while the page has notes.
struct MarginNotesButton: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var painter = MarginPainter.shared

    var body: some View {
        if tab.hasMarginNotes {
            Button { painter.shown.toggle() } label: {
                Image(systemName: painter.shown ? "note.text" : "note")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(painter.shown ? Palette.accent : Palette.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shortcutHelp(painter.shown ? "Hide margin notes" : "Show margin notes", "view.marginNotes")
        }
    }
}
