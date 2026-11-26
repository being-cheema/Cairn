import AppIntents
import AppKit

// Shortcuts' way in: ask Claude, prepare a playbook, copy the page as
// Markdown, switch space.
//
// None of them starts Claude. The two about Claude put words in the panel's
// box and open it: your own press of Send is what starts a run, and is the
// consent for it (ClaudeSession). Nothing here approves, sends or runs
// anything, since a shortcut can be run by an automation with nobody there.
//
// macOS lists an app's intents from metadata made by Xcode's
// appintentsmetadataprocessor. build.sh builds with SwiftPM, which doesn't
// run it, so the app build.sh makes offers none of these to Shortcuts or
// Spotlight yet.

/// What each does, apart from the framework, so it is tested without it.
@MainActor
enum ShortcutActions {
    static let longestAsk = 4_000

    enum Refused: Error, Equatable, CustomLocalizedStringResourceConvertible {
        case noWindow, nothing, noPlaybook, privatePage, closedSite, noSpace

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .noWindow: return "There is no window open."
            case .nothing: return "There is nothing there."
            case .noPlaybook: return "There is no playbook by that name."
            case .privatePage: return "A private tab isn't copied by a shortcut."
            case .closedSite: return "You closed this site to agents, so a shortcut doesn't copy it."
            case .noSpace: return "There is no space by that name."
            }
        }
    }

    /// Words for the panel's box, to read and send. No control characters
    /// but new lines, and no longer than the box is for.
    static func words(_ text: String) -> String {
        let clean = text.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }
        return String(String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(longestAsk))
    }

    /// Put after what you had typed there, never over it. Never sent.
    static func fill(_ text: String, in session: ClaudeSession) throws {
        let new = words(text)
        guard !new.isEmpty else { throw Refused.nothing }
        session.draft = session.draft.isEmpty ? new : session.draft + "\n" + new
    }

    /// A playbook called in the box, as picking it there would, with what
    /// goes after its name. One goes first in a message, so it takes the box.
    static func prepare(playbook named: String, words extra: String, in session: ClaudeSession,
                        among books: [Playbook]) throws {
        let wanted = named.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "/" }.lowercased()
        guard let book = books.first(where: { $0.name == wanted }) else { throw Refused.noPlaybook }
        let after = words(extra)
        let call = "/" + book.name + " " + after
        session.draft = session.draft.isEmpty ? call : call + "\n" + session.draft
    }

    /// Whether a shortcut may have the front page: not a private one, and
    /// not one on a site closed to agents, since what a shortcut copies it
    /// can pass anywhere.
    static func mayCopy(_ tab: Tab?) throws {
        guard let tab, tab.isWeb else { throw Refused.nothing }
        guard !tab.shy else { throw Refused.privatePage }
        guard !AgentControl.isVaulted(tab) else { throw Refused.closedSite }
    }

    static func space(named: String, among spaces: [(id: UUID, name: String)]) throws -> UUID {
        let wanted = named.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let found = spaces.first(where: { $0.name.compare(wanted, options: .caseInsensitive) == .orderedSame }) else {
            throw Refused.noSpace
        }
        return found.id
    }

    static func front() throws -> Browser {
        guard let browser = Browsers.all.first(where: { $0.window?.isKeyWindow == true }) ?? Browsers.primary else {
            throw Refused.noWindow
        }
        return browser
    }

    /// The panel up, to be read.
    static func showPanel(_ browser: Browser) {
        NSApp.activate()
        browser.window?.makeKeyAndOrderFront(nil)
        if !(browser.sidePanelShown && browser.sidePanel == .claude) { browser.toggleClaudePanel() }
    }
}

struct AskCairnIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Claude"
    static let description = IntentDescription("Puts your question in the Claude panel. Nothing is sent until you press Send.")
    static let openAppWhenRun = true

    @Parameter(title: "Question")
    var question: String

    @MainActor func perform() async throws -> some IntentResult {
        let browser = try ShortcutActions.front()
        try ShortcutActions.fill(question, in: browser.claude)
        ShortcutActions.showPanel(browser)
        return .result()
    }
}

struct RunCairnPlaybookIntent: AppIntent {
    // "Prepare", not "Run": it runs when you press Send.
    static let title: LocalizedStringResource = "Prepare a Playbook"
    static let description = IntentDescription("Calls a playbook in the Claude panel's box. It runs when you press Send.")
    static let openAppWhenRun = true

    @Parameter(title: "Playbook name")
    var playbook: String

    @Parameter(title: "What goes after its name", default: "")
    var words: String

    @MainActor func perform() async throws -> some IntentResult {
        let browser = try ShortcutActions.front()
        try ShortcutActions.prepare(playbook: playbook, words: words, in: browser.claude, among: Playbooks.all())
        ShortcutActions.showPanel(browser)
        return .result()
    }
}

struct CopyActiveTabMarkdownIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Page as Markdown"
    static let description = IntentDescription("Copies the front tab's main content to the clipboard as Markdown.")

    @MainActor func perform() async throws -> some IntentResult {
        let browser = try ShortcutActions.front()
        try ShortcutActions.mayCopy(browser.active)
        browser.copyPageAsMarkdown()
        return .result()
    }
}

struct SwitchCairnSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Space"
    static let description = IntentDescription("Goes to a space by its name.")
    static let openAppWhenRun = true

    @Parameter(title: "Space name")
    var space: String

    @MainActor func perform() async throws -> some IntentResult {
        let browser = try ShortcutActions.front()
        guard browser.prefs.usesSpaces else { throw ShortcutActions.Refused.noSpace }
        let id = try ShortcutActions.space(named: space, among: browser.spaces.map { (id: $0.id, name: $0.name) })
        browser.switchSpace(to: id)
        return .result()
    }
}
