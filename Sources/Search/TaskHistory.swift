import SwiftUI

// The panel's Task History (TaskLedger): each task as a line, its receipt
// when pressed, and from there its tabs again or a follow-up. Everything in
// it is shown as plain words: titles and quoted labels are websites' words.

struct TaskHistory: View {
    @ObservedObject var session: ClaudeSession
    let close: () -> Void

    @State private var records: [TaskRecord] = []
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
        .onAppear { records = TaskLedger.all() }
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
