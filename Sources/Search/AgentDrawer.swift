import SwiftUI

// Settings › About › Developer, under Coding agents: how to set an agent up,
// and who is let in without asking, each with Revoke.
//
// There is nothing to switch on here. The list is AgentTrust's, which only a
// tick of yours on the question in the window adds to; this reads it and
// takes from it. What is copied is the way to reach this copy of the browser,
// and never a pass: the side panel's own is made for one run and handed to
// that run alone (PanelRun), and an agent set up by hand is always asked.

/// The text that sets an outside agent up with this copy's cairn-mcp.
enum AgentSetup {
    /// A word as a shell takes it whole, whatever is in it.
    static func quoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `world`: a test run's, so that what it copies reaches that run.
    static func arguments(world: String?) -> [String] {
        world.map { ["--world", $0] } ?? []
    }

    static func command(path: String, world: String? = nil) -> String {
        (["claude mcp add cairn --", quoted(path)] + arguments(world: world).map(quoted)).joined(separator: " ")
    }

    static func json(path: String, world: String? = nil) -> String {
        let config: [String: Any] = ["mcpServers": ["cairn": ["command": path, "args": arguments(world: world)]]]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Both, each said for what it is. The headings are shell comments, so
    /// the first part pastes into Terminal as it stands.
    static func both(path: String, world: String? = nil) -> String {
        """
        # Claude Code: run this in Terminal
        \(command(path: path, world: world))

        # An agent set up by a JSON file: add this to it
        \(json(path: path, world: world))
        """
    }

    /// The line that links the `cairn` command line (CairnCLI) into a folder
    /// on your PATH. Only ever shown and copied: nothing here runs it or
    /// writes outside the app.
    static func cliLink(path: String) -> String {
        "mkdir -p ~/.local/bin && ln -sf \(quoted(path)) ~/.local/bin/cairn"
    }

    /// An app opened straight from a download or a disk image runs from a
    /// copy macOS makes and throws away: a path into it won't last.
    static func passing(_ path: String) -> Bool { path.contains("/AppTranslocation/") }
}

/// What one remembered agent is shown as: every part AgentTrust keeps.
enum AgentEntryWords {
    static func state(_ entry: RememberedAgent, now: Date = Date()) -> String {
        if entry.expired(at: now) { return "Run out: asked again next time" }
        if entry.suspended == true { return "Asked again since you stopped it" }
        return "Allowed without asking"
    }

    /// The name is the program's own word for itself; the signer is its
    /// signature's.
    static func lines(_ entry: RememberedAgent, day: (Date) -> String = day, ago: (Date) -> String = ago) -> [String] {
        var out = [
            "Calls itself “\(entry.client)”",
            "Signed by \(entry.signer) (\(entry.identifier), team \(entry.team.isEmpty ? "none" : entry.team))",
        ]
        if !entry.path.isEmpty { out.append("Last seen at \(entry.path)") }
        out.append("Added \(day(entry.added)) · last used \(ago(entry.used)) · until \(day(entry.expires))")
        return out
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func ago(_ date: Date) -> String {
        let format = RelativeDateTimeFormatter()
        format.unitsStyle = .full
        return Date().timeIntervalSince(date) < 60 ? "just now" : format.localizedString(for: date, relativeTo: Date())
    }

    /// What the list says when it has nobody in it.
    static func nobody(usable: Bool) -> String {
        usable
            ? "Nobody is let in without asking. Tick “Always allow” when one asks, where it is offered."
            : "This build can't save lasting permission, so every outside agent is asked about each time it connects."
    }
}

/// The drawer: shut until opened.
struct RememberedAgents: View {
    @ObservedObject private var trust: AgentTrust
    @State private var open: Bool
    @State private var copied = false
    @State private var linked = false

    private let tool: URL?

    /// The app's own list and this copy's cairn-mcp, shut. A test hands in
    /// its own.
    init(trust: AgentTrust? = nil, open: Bool = false, tool: URL? = ClaudeCode.mcpTool()) {
        self.tool = tool
        _trust = ObservedObject(wrappedValue: trust ?? .shared)
        _open = State(initialValue: open)
    }

    var body: some View {
        Rule()
        SettingRow(icon: "key.horizontal", title: "Setup and trusted agents", detail: summary) {
            Pill(open ? "Hide" : "Show") { withAnimation(Motion.quick) { open.toggle() } }
        }
        if open {
            setup
            if trust.remembered.isEmpty {
                Rule()
                Nothing(AgentEntryWords.nobody(usable: trust.usable))
            } else {
                ForEach(trust.remembered) { entry in
                    Rule()
                    row(entry)
                }
            }
        }
    }

    private var summary: String {
        guard trust.usable else { return "This build can't keep trusted agents" }
        let count = trust.remembered.count
        return count == 0 ? "No agent is let in without asking" : count == 1 ? "1 agent remembered" : "\(count) agents remembered"
    }

    @ViewBuilder
    private var setup: some View {
        Rule()
        if let tool {
            SettingRow(icon: "doc.on.clipboard", title: "Set up an agent",
                       detail: AgentSetup.passing(tool.path)
                           ? "\(Brand.name) is running from a temporary copy: move it to Applications first, or this path will stop working."
                           : "The Claude Code command and a JSON entry for this copy of \(Brand.name). Outside agents are still asked when they connect.") {
                Pill(copied ? "Copied" : "Copy MCP Config") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentSetup.both(path: tool.path, world: Store.world), forType: .string)
                    copied = true
                }
            }
            Text(verbatim: AgentSetup.command(path: tool.path, world: Store.world))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 52)
                .padding(.trailing, 14)
                .padding(.bottom, 10)
            Rule()
            SettingRow(icon: "terminal", title: "Command line",
                       detail: "cairn md <url>, cairn ask \"…\", cairn audit <local url>. It asks you like any other agent, and cairn ask only fills the Claude panel's box: you press Send. This copies a line that links it into ~/.local/bin; nothing is written until you run it.") {
                Pill(linked ? "Copied" : "Copy Install Line") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentSetup.cliLink(path: tool.deletingLastPathComponent().appendingPathComponent("cairn").path),
                                                   forType: .string)
                    linked = true
                }
            }
        } else {
            Nothing("This copy of \(Brand.name) has no cairn-mcp for an agent to run. A copy made by build.sh has one.")
        }
    }

    private func row(_ entry: RememberedAgent) -> some View {
        SettingRow(icon: "checkmark.shield", title: entry.client, detail: AgentEntryWords.state(entry)) {
            Pill("Revoke", tint: Tone.remove) { revoke(entry) }
        }
        .modifier(Particulars(lines: AgentEntryWords.lines(entry)))
    }

    private func revoke(_ entry: RememberedAgent) {
        Ask.sure("Revoke “\(entry.client)”?",
                 detail: "It will be asked about the next time it connects. A task it is running now isn't stopped: press Stop for that.",
                 confirm: "Revoke", returnCancels: true) {
            trust.forget(entry.id)
        }
    }

    /// Under a row, what is known of it, in full rather than behind a button.
    private struct Particulars: ViewModifier {
        let lines: [String]

        func body(content: Content) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                content
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines, id: \.self) { line in
                        // A program's own path and name: shown, never read as
                        // markup.
                        Text(verbatim: line)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 52)
                .padding(.trailing, 14)
                .padding(.bottom, 10)
            }
        }
    }
}
