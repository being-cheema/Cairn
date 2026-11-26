import SwiftUI

// The panel's Task History (TaskLedger): each task as a line, its receipt
// when pressed, and from there its tabs again or a follow-up. Everything in
// it is shown as plain words: titles and quoted labels are websites' words.

struct TaskHistory: View {
    @ObservedObject var session: ClaudeSession
    let close: () -> Void

    @State private var records: [TaskRecord] = []
    @State private var macros: [FastMacro] = []
    /// Why the last Run or Save didn't happen.
    @State private var trouble: String?
    @State private var open: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Task History")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                if !records.isEmpty {
                    Quick("Delete All", tint: Palette.muted) {
                        Ask.sure("Delete the task history?", detail: "The records of what each task did are removed from this Mac.",
                                 confirm: "Delete All", returnCancels: true) {
                            TaskLedger.removeAll()
                            records = []
                        }
                    }
                }
            }
            Text(session.browser?.prefs.keepsTaskHistory == false
                 ? "Task History is off (Settings › About), so new tasks aren't kept. Delete All removes what was kept before."
                 : "Kept on this Mac: what you asked, with recognisable secrets hidden, the sites, your answers to approvals and the tabs left to you. Not Claude's replies.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !macros.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fast Macros").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                    ForEach(macros) { macro in
                        MacroRow(session: session, macro: macro, trouble: $trouble, close: close) {
                            MacroStore.remove(macro.id)
                            macros = MacroStore.all()
                        }
                    }
                }
            }
            if let trouble {
                Text(verbatim: trouble).font(.system(size: 11)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if records.isEmpty {
                Text("No tasks yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(records) { record in row(record) }
                    }
                }
                .frame(height: 360)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear {
            records = TaskLedger.all()
            macros = MacroStore.all()
        }
    }

    private func row(_ record: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open = open == record.id ? nil : record.id } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: record.prompt)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(open == record.id ? 6 : 1)
                        .multilineTextAlignment(.leading)
                    Text(verbatim: Self.summary(record))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open == record.id { receipt(record) }
        }
        .padding(8)
        .background(Palette.wash.opacity(open == record.id ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func receipt(_ record: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let model = record.model { part("Model", [model]) }
            if !record.hosts.isEmpty { part("Sites", [record.hosts.joined(separator: ", ")]) }
            if !record.approvals.isEmpty { part("Approvals", record.approvals.map { Self.say($0) }) }
            // The addresses in full, so what Reopen opens is seen first.
            if !record.tabs.isEmpty { part("Tabs left to you", record.tabs.map { "\($0.title)\n\($0.url)" }) }
            if let recorder = MacroStore.drafts[record.id] {
                if let macro = MacroStore.macro(from: record, recorder) {
                    Quick("Save as Fast Macro") {
                        if MacroStore.save(macro) {
                            MacroStore.draft(record.id, nil)
                            macros = MacroStore.all()
                            trouble = nil
                        } else {
                            trouble = "The macro couldn't be saved. Delete one if you have \(MacroStore.most)."
                        }
                    }
                    .help("Keeps these steps on this Mac, to run again without Claude")
                } else if record.outcome == .completed, let why = recorder.spoiled {
                    Text(verbatim: "Can't be a Fast Macro: \(why).")
                        .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                }
            }
            HStack(spacing: 6) {
                if !record.reopenable.isEmpty {
                    Quick("Reopen Tabs") {
                        guard let browser = session.browser else { return }
                        for url in record.reopenable { _ = browser.open(url, foreground: false) }
                        close()
                    }
                    .help("Opens these addresses in your own tabs, signed in as you are")
                }
                Quick("Follow Up in New Task") {
                    session.followUp(record)
                    close()
                }
                Spacer(minLength: 0)
                Quick("Delete", tint: Palette.muted) {
                    TaskLedger.remove(record.id)
                    records.removeAll { $0.id == record.id }
                }
            }
        }
    }

    /// A saved macro: its steps in full before Run, and Run pressed only by
    /// a click of yours on it (AgentControl.startReplay).
    private struct MacroRow: View {
        @ObservedObject var session: ClaudeSession
        let macro: FastMacro
        @Binding var trouble: String?
        let close: () -> Void
        let delete: () -> Void

        @State private var open = false
        @State private var spot = Spot()
        private final class Spot { weak var view: NSView?; var since: TimeInterval = 0 }

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    open.toggle()
                    spot.since = ProcessInfo.processInfo.systemUptime
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                        Text(verbatim: macro.name).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Palette.ink)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    ForEach(Array(macro.steps.enumerated()), id: \.offset) { number, step in
                        Text(verbatim: "\(number + 1). \(step.said)")
                            .font(.system(size: 11)).foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Runs without Claude, in tabs of its own, signed in to nothing. Paying, sending and leaving its sites still wait for your click. It stops if a page has changed.")
                        .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button { run() } label: {
                            Text("Run")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Palette.ground)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Palette.ink, in: Capsule())
                                .background(ClickSpot { spot.view = $0 })
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                        Quick("Delete", tint: Palette.muted) { delete() }
                    }
                }
            }
            .padding(8)
            .background(Palette.wash.opacity(open ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        private func run() {
            guard let browser = session.browser else { return }
            let macro = macro, session = session
            let why = AgentControl.shared.startReplay(macro, in: browser, event: NSApp.currentEvent, on: spot.view,
                                                      shownAt: spot.since) { [weak browser] result in
                switch result {
                case .stopped(let why):
                    browser?.announce("Macro stopped: \(why)")
                case .finished(let page):
                    // Attached and written, not sent: sending is your Send.
                    session.mention(.macroResult(page, name: macro.name))
                    if session.draft.isEmpty { session.draft = MacroStore.summaryRequest(macro) }
                    browser?.announce("Macro finished. Press Send in the Claude panel for a summary.")
                }
            }
            if let why { trouble = why } else { close() }
        }
    }

    private func part(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.muted)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static let when: DateFormatter = {
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out
    }()

    static func summary(_ record: TaskRecord) -> String {
        let outcome: String
        switch record.outcome {
        case .completed: outcome = "Completed"
        case .stopped: outcome = "Stopped"
        case .denied: outcome = "You said no"
        case .failed: outcome = "Failed"
        }
        return "\(when.string(from: record.time)) · \(outcome)"
    }

    static func say(_ receipt: TaskRecord.Receipt) -> String {
        let answer: String
        switch receipt.answer {
        // A sign-in handed back is your Resume, not an approval.
        case "approved": answer = receipt.reason == "signIn" ? "You signed in and resumed" : "Approved"
        case "declined": answer = "Declined"
        default: answer = "No answer"
        }
        return "\(answer): \(receipt.what)"
    }
}
