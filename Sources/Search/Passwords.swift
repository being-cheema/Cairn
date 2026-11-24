import SwiftUI
import UniformTypeIdentifiers

/// The one tint for taking something away, wherever it is on this page.
private enum Tone {
    static let remove = Color.red.opacity(0.75)
}

/// What the Passwords page puts on the clipboard goes the same way: this Mac's
/// only, marked concealed and transient (what clipboard managers go by to keep
/// it out of their history), and taken off again after a while unless
/// something else has been copied since.
enum KeptClipboard {
    static func put(_ text: String, clearAfter seconds: TimeInterval?) {
        let board = NSPasteboard.general
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString(text, forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        guard let seconds else { return }
        let copied = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if board.changeCount == copied { board.clearContents() }
        }
    }
}

/// Typed changes are not thrown away without asking. Keep editing is the
/// first button, so Return is the safe answer.
@MainActor
private func confirmDiscard(then: @escaping () -> Void) {
    if Store.testing, let yes = Ask.testing {
        if yes { then() }
        return
    }
    let alert = NSAlert()
    alert.messageText = "Discard changes?"
    alert.informativeText = "What you typed hasn't been kept."
    alert.addButton(withTitle: "Keep editing")
    alert.addButton(withTitle: "Discard")
    if alert.runModal() == .alertSecondButtonReturn { then() }
}

/// An error with a mark of its own, so it never leans on colour alone.
private func errorLine(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
        Image(systemName: "exclamationmark.circle")
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.accent)
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
}

/// Every password kept: a list on the left, the one picked on the right. The
/// same rule as ever: a password is never shown until you have proved you are
/// you (Vault.Unlock), and never for longer than it takes to read it.
struct PasswordsPanel: View {
    @ObservedObject var browser: Browser

    enum Tab: String, CaseIterable, Identifiable {
        case all = "All"
        case codes = "Codes"
        case passkeys = "Passkeys"
        case health = "Health"
        case bring = "Import & export"
        var id: String { rawValue }
    }

    /// What the right side is doing besides showing one.
    enum Editing: Equatable {
        case new
        case existing(Item)
    }

    @FocusState private var hunting: Bool
    @FocusState private var focusedRow: String?
    @FocusState private var focusedTab: Tab?
    /// The open form holds typed changes not yet kept.
    @State private var editDirty = false
    /// The Mac's say-so was asked for on Codes or Health and refused.
    @State private var unlockRefused = false
    /// The Codes tab has been read once since it was opened.
    @State private var codesLoaded = false
    @State private var tab = Tab.all
    @State private var selected: String?
    @State private var editing: Editing?
    /// What Search kept under its own label, not yet copied (Vault.legacy).
    @State private var legacy: [Kept] = []
    @State private var copying = false
    /// A passwords file read and waiting for Bring in: what it would do, held
    /// in memory with its passwords until it is taken in or cancelled.
    @State private var pending: PasswordImport.Plan?
    @State private var pendingFile: URL?
    @State private var choice = PasswordImport.Duplicates.skip
    @State private var reading = false
    @State private var writing = false
    @State private var finished: PasswordImport.Result?
    @State private var trashed = false
    /// Accounts with a code, while the Codes tab is up: their keys are held
    /// only then, and let go on leaving it.
    @State private var coded: [CodeItem] = []
    @State private var loadingCodes = false
    /// What the last check found. Holds no password, only which accounts are
    /// flagged and why; dropped when the list changes.
    @State private var report: PasswordHealth.Report?
    @State private var checking = false
    /// The passkeys Cairn keeps (no keys: listing reads none).
    @State private var passkeyList: [PasskeyRecord] = []
    @State private var healthFilter: PasswordHealth.Kind?
    /// A backup file waiting for its passphrase, and the passphrase being typed.
    @State private var vaultData: Data?
    @State private var openPass = ""
    @State private var openError: String?
    /// Making a backup: the two passphrase fields, while they are up.
    @State private var askingBackup = false
    @State private var backupPass = ""
    @State private var backupAgain = ""
    @State private var exporting = false
    /// The last file taken out, for the line under the export card.
    @State private var exported: Exported?
    @State private var exportedTrashed = false
    @State private var cameFromBackup = false

    private struct Exported {
        let url: URL
        let plain: Bool
        let count: Int
        let missed: Int
    }

    /// The list as the search leaves it, one row per account.
    private var rows: [Kept] { browser.shownSites.flatMap(\.logins) }
    private var picked: Kept? { rows.first { $0.id == selected } }

    var body: some View {
        Plate("Passwords", width: 860, close: { browser.managing = false }) {
            VStack(alignment: .leading, spacing: 16) {
                tabs
                switch tab {
                case .all: all
                case .codes: codesTab
                case .passkeys: passkeysTab
                case .health: healthTab
                case .bring: bring
                }
            }
        } foot: {
            HStack {
                Text(browser.saved.count == 1 ? "1 password" : "\(browser.saved.count) passwords")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
            }
        }
        .fromSettings()
        .onChange(of: tab) { _, now in
            // Codes and Health only read anything when their button is pressed.
            unlockRefused = false
            if now != .codes { coded = []; codesLoaded = false }
            if now == .passkeys { passkeyList = PasskeyStore.all() }
        }
        .onChange(of: browser.saved) { _, _ in report = nil }
        .animation(Motion.settle, value: tab)
        .animation(Motion.settle, value: editing)
        .onAppear { hunting = true }
        .task { await refreshLegacy() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { switchTab(.bring); readFile(url) }
            }
            return true
        }
        .onChange(of: browser.hunting) { _, _ in
            // The one picked fell out of the search: nothing is picked.
            if let selected, !rows.contains(where: { $0.id == selected }) { self.selected = nil; editing = nil }
        }
    }

    // MARK: - the tabs

    /// Leaving the All tab with typed changes in the Add or Edit form asks
    /// first, as picking another row does.
    private func switchTab(_ next: Tab) {
        guard next != tab else { return }
        if tab == .all, editing != nil, editDirty {
            confirmDiscard { editDirty = false; editing = nil; tab = next }
        } else {
            tab = next
        }
    }

    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach(Tab.allCases) { each in
                Button { switchTab(each) } label: {
                    VStack(spacing: 5) {
                        Text(each.rawValue)
                            .font(.system(size: 13, weight: tab == each ? .medium : .regular))
                            .foregroundStyle(tab == each ? Palette.ink : Palette.muted)
                        Rectangle()
                            .fill(tab == each ? Palette.accent : .clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focusedTab, equals: each)
                .focusEffectDisabled()
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Palette.accent, lineWidth: 1.5)
                        .padding(-3)
                        .opacity(focusedTab == each ? 1 : 0)
                )
                .accessibilityAddTraits(tab == each ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - all of them

    private var all: some View {
        HStack(alignment: .top, spacing: 16) {
            // With nothing kept there is nothing to search or list: the one
            // empty state is the detail pane's.
            if !browser.saved.isEmpty {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Hunt(text: $browser.hunting, prompt: "Search sites and accounts", focus: $hunting)
                        Pill("Add", filled: true) { guardEdits { selected = nil; editing = .new } }
                    }
                    list
                    if !rows.isEmpty {
                        HStack {
                            Spacer(minLength: 0)
                            Pill(removeAllTitle, tint: Tone.remove) { browser.forgetShown() }
                                .disabled(browser.forgetting)
                        }
                    }
                }
                .frame(width: 300)
            }

            Card { detail }
                .frame(maxWidth: .infinity)
        }
        .frame(height: 440)
    }

    /// What Remove below the list takes: the list as it stands, so the
    /// search that narrows it is right there to see (Browser.forgetShown).
    private var removeAllTitle: String {
        let n = rows.count
        if browser.hunting.trimmingCharacters(in: .whitespaces).isEmpty { return n == 1 ? "Remove it…" : "Remove all \(n)…" }
        return n == 1 ? "Remove this one…" : "Remove these \(n)…"
    }

    /// Runs `go` now, or once typed changes in the open form are let go of.
    private func guardEdits(_ go: @escaping () -> Void) {
        if editing != nil, editDirty {
            confirmDiscard { editDirty = false; go() }
        } else {
            go()
        }
    }

    /// Up and Down move the pick through the list, Delete removes it (asking,
    /// as the Remove button does).
    private func step(_ by: Int) {
        guard !rows.isEmpty else { return }
        let at = rows.firstIndex { $0.id == selected }
        let next = min(max((at ?? (by > 0 ? -1 : rows.count)) + by, 0), rows.count - 1)
        let id = rows[next].id
        guard id != selected else { return }
        guardEdits { editing = nil; selected = id; focusedRow = id }
    }

    @ViewBuilder
    private var list: some View {
        if rows.isEmpty {
            Card {
                Nothing(browser.saved.isEmpty
                        ? "Nothing kept yet. Sign in somewhere and say yes, or add one."
                        : "Nothing matches.", art: browser.saved.isEmpty ? "approval" : "search")
            }
            Spacer(minLength: 0)
        } else {
            ScrollView(showsIndicators: false) {
                Card {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, login in
                        if index > 0 { Rule() }
                        Row(login: login, picked: selected == login.id, flagged: report?.flagged.contains(login.id) ?? false,
                            focus: $focusedRow) {
                            guardEdits { editing = nil; selected = login.id }
                        }
                    }
                }
                .padding(.bottom, 2)
            }
            .onKeyPress(.upArrow) { step(-1); return .handled }
            .onKeyPress(.downArrow) { step(1); return .handled }
            .onKeyPress(.delete) { removePicked() }
            .onKeyPress(.deleteForward) { removePicked() }
        }
    }

    private func removePicked() -> KeyPress.Result {
        guard let login = picked else { return .ignored }
        browser.forget(login) { selected = nil }
        return .handled
    }

    @ViewBuilder
    private var detail: some View {
        if let editing {
            EditForm(browser: browser, editing: editing, dirty: $editDirty) { saved in
                self.editing = nil
                if let saved { selected = saved.id }
            }
            .id(editing == .new ? "new" : "edit-\(selected ?? "")")
        } else if let login = picked {
            Detail(
                login: login,
                edit: { item in editing = .existing(item) },
                copy: { browser.copy(login) },
                announce: { browser.announce($0) },
                forget: { browser.forget(login) { selected = nil } }
            )
            .id(login.id)
        } else {
            VStack(spacing: 14) {
                Spacer()
                if browser.saved.isEmpty {
                    ArtPicture(name: "approval", size: 64)
                    Text("No passwords kept yet")
                        .font(Typeface.heading(16, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text("Sign in somewhere and say yes, or add one yourself, or bring in what another manager or browser holds.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 340)
                    HStack(spacing: 8) {
                        Pill("Add", filled: true) { selected = nil; editing = .new }
                        Pill("Import & export") { tab = .bring }
                    }
                } else {
                    Text("Pick one to see it.")
                        .font(Typeface.heading(14))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    // MARK: - codes

    private struct CodeItem: Identifiable {
        let id: String
        let name: String
        let detail: String
        let key: TOTP.Key
    }

    /// A tab that reads the passwords says so, and waits for its button: only
    /// that asks the Mac who you are. A refusal leaves you here.
    private func gate(_ text: String, button: String, busy: String?, action: @escaping () -> Void) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                if let busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(Typeface.heading(14)).foregroundStyle(Palette.muted)
                    }
                } else {
                    Text(text)
                        .font(Typeface.heading(14))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if unlockRefused { errorLine("Not unlocked.") }
                    Pill(button, filled: true, action: action)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var codesTab: some View {
        if coded.isEmpty {
            if codesLoaded {
                Card {
                    Nothing("No verification codes yet. Add a setup key to a password (Edit), or bring in a file that has them.", art: "approval")
                }
            } else {
                gate("Your verification codes are kept with your passwords. Showing them needs your Mac's say-so.",
                     button: "Show codes", busy: loadingCodes ? "Reading…" : nil, action: loadCodes)
            }
        } else {
            ScrollView(showsIndicators: false) {
                Card {
                    ForEach(Array(coded.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Rule() }
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
                                Text(item.detail).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            CodeLine(key: item.key) { browser.announce($0) }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }
            .frame(maxHeight: 440)
        }
    }

    /// Asks once (Vault.Unlock), then reads the accounts that keep a setup
    /// key, off the main thread. Gone again when the tab is left.
    private func loadCodes() {
        guard !loadingCodes else { return }
        loadingCodes = true
        unlockRefused = false
        let all = browser.saved
        Vault.Unlock.ask("show your verification codes") { ok in
            guard ok else { loadingCodes = false; unlockRefused = true; return }
            Task {
                let found: [CodeItem] = await Task.detached(priority: .userInitiated) {
                    all.compactMap { kept -> CodeItem? in
                        guard let item = Vault.item(of: kept), let text = item.extras.totp, let key = TOTP.key(from: text) else { return nil }
                        let title = item.extras.title.flatMap { $0.isEmpty ? nil : $0 } ?? kept.host
                        return CodeItem(id: kept.id, name: title, detail: kept.user.isEmpty ? kept.host : kept.user, key: key)
                    }
                }.value
                loadingCodes = false
                if tab == .codes { coded = found; codesLoaded = true }
            }
        }
    }

    /// The six digits now, how long they last, and Copy. Ticks every second;
    /// the key is the only thing held.
    private struct CodeLine: View {
        let key: TOTP.Key
        let announce: (String) -> Void

        var body: some View {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let code = TOTP.code(for: key, at: context.date)
                let left = TOTP.secondsLeft(key, at: context.date)
                HStack(spacing: 10) {
                    Text(TOTP.spaced(code))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                    Text("\(left)s")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(left <= 5 ? Palette.accent : Palette.muted)
                        .frame(width: 26, alignment: .trailing)
                        // Colour alone says it is about to change; a reader
                        // of the screen is told too.
                        .accessibilityLabel("Time left")
                        .accessibilityValue("\(left) seconds left")
                    Quick("Copy") {
                        // A code is good for a minute at most: not left on
                        // the clipboard for longer than a password would be.
                        KeptClipboard.put(code, clearAfter: 30)
                        announce("Code copied")
                    }
                }
            }
        }
    }

    // MARK: - passkeys

    private static let when: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    @ViewBuilder
    private var passkeysTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            if passkeyList.isEmpty {
                Card {
                    Nothing("No passkeys kept here yet. When a site offers to make one, say yes and \(Brand.name) keeps it, behind Touch ID.",
                            art: "approval")
                }
            } else {
                ScrollView(showsIndicators: false) {
                    Card {
                        ForEach(Array(passkeyList.enumerated()), id: \.element.id) { index, record in
                            if index > 0 { Rule() }
                            HStack(spacing: 12) {
                                Mark(icon: Favicons.shared.cached(record.rp), letter: record.rp.first.map { String($0).uppercased() } ?? "•", size: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(record.rp).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
                                    Text(record.userName.isEmpty ? record.displayName : record.userName)
                                        .font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                Text(record.lastUsed.map { "Used \(Self.when.string(from: $0))" } ?? "Made \(Self.when.string(from: record.created))")
                                    .font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                                Quick("Remove", tint: Tone.remove) { removePasskey(record) }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }
                }
                .frame(maxHeight: 330)
            }
            Text("Passkeys made here stay on this Mac, and are signed only after Touch ID. iCloud Keychain passkeys can't be used here: sign in another way once, then make a new one.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .help("Apple lets only a paid developer's app use passkeys kept in iCloud Keychain or the Passwords app, so \(Brand.name) can't read or move them.")
        }
    }

    /// Asks the Mac, then asks again in words: a site's passkey is not a
    /// thing to get back.
    private func removePasskey(_ record: PasskeyRecord) {
        Ask.sure(
            "Remove the passkey for \(record.rp)?",
            detail: "\(record.userName.isEmpty ? "The account" : record.userName) can no longer sign in with it. If the site has no other way in for you, you may be locked out.",
            confirm: "Remove",
            returnCancels: true
        ) {
            Vault.Unlock.ask("remove the passkey for \(record.rp)") { ok in
                guard ok else { return }
                if PasskeyStore.remove(record) { passkeyList = PasskeyStore.all() } else { browser.announce("Couldn't remove it") }
            }
        }
    }

    // MARK: - health

    /// Asks once (Vault.Unlock), then reads every password off the main
    /// thread and checks them against each other and a short list of the
    /// commonest. Only the findings come back.
    private func checkHealth() {
        guard !checking else { return }
        checking = true
        unlockRefused = false
        let all = browser.saved
        Vault.Unlock.ask("check your passwords") { ok in
            guard ok else { checking = false; unlockRefused = true; return }
            Task {
                let found = await Task.detached(priority: .userInitiated) {
                    let entries = all.compactMap { kept -> PasswordHealth.Entry? in
                        guard let item = Vault.item(of: kept) else { return nil }
                        let title = item.extras.title ?? ""
                        return PasswordHealth.Entry(id: kept.id, name: title.isEmpty ? kept.host : title, user: kept.user,
                                                    password: item.password, changed: item.extras.changed, clear: kept.clear)
                    }
                    return PasswordHealth.check(entries)
                }.value
                checking = false
                report = found
            }
        }
    }

    private func jump(to id: String) {
        browser.hunting = ""
        editing = nil
        selected = id
        tab = .all
    }

    @ViewBuilder
    private var healthTab: some View {
        if let report {
            // A filter with nothing left under it is no filter (the last weak
            // one was fixed): the rest of the list is not hidden by it.
            let active = healthFilter.flatMap { report.count($0) > 0 ? $0 : nil }
            let shown = report.findings.filter { finding in active.map { finding.kinds.contains($0) } ?? true }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ForEach(PasswordHealth.Kind.allCases) { kind in
                        let n = report.count(kind)
                        Button { healthFilter = active == kind ? nil : kind } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(n)")
                                    .font(Typeface.heading(24, weight: .medium))
                                    .foregroundStyle(Palette.ink)
                                Text(kind.rawValue).font(.system(size: 12)).foregroundStyle(Palette.ink)
                                Text(kind.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.muted)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(active == kind ? Palette.accent.opacity(0.12) : Palette.wash))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(active == kind ? Palette.accent : Palette.hairline, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(active == kind ? .isSelected : [])
                        .help(kind.help)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if shown.isEmpty {
                    Card {
                        Nothing(report.findings.isEmpty ? "Nothing to fix in \(count(report.checked, "password", "passwords"))."
                                : "Nothing under \(active?.rawValue ?? "that").", art: "approval")
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        Card {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, finding in
                                if index > 0 { Rule() }
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(finding.name).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
                                        Text(finding.user.isEmpty ? finding.why : "\(finding.user) · \(finding.why)")
                                            .font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(2)
                                    }
                                    Spacer(minLength: 8)
                                    Quick("Show") { jump(to: finding.id) }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                            }
                        }
                    }
                    .frame(maxHeight: 330)
                }
                Text("Checked on this Mac, \(count(report.checked, "password", "passwords")), and nothing was sent anywhere. That is also why no password is looked up in a list of leaked ones: that would mean sending something out.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            gate("Checking reads every password on this Mac, to find ones used twice, weak or old. It needs your Mac's say-so, and nothing is sent anywhere.",
                 button: "Check passwords", busy: checking ? "Checking…" : nil, action: checkHealth)
        }
    }

    // MARK: - bringing them in

    private var bring: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let finished {
                doneCard(finished)
            } else if let plan = pending {
                previewCard(plan)
            } else if vaultData != nil {
                vaultCard
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("From another manager or browser")
                            .font(Typeface.heading(15, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        Text("Drop a passwords file here, or pick one. The Passwords app, Safari, Chrome, Edge, Brave, Firefox, Bitwarden, 1Password, LastPass, KeePass and Dashlane all export one, and so does \(Brand.name) (a backup file asks for its passphrase); its kind is worked out from its columns. You see what it would do before anything is kept.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Pill(reading ? "Reading…" : "Passwords file…", filled: true) { chooseFile() }
                                .disabled(reading)
                            Pill("Another browser…") { browser.lead(to: InternalPage(.importing)) }
                        }
                        Text("Another browser reads its saved passwords straight from its profile: macOS asks once for that browser's keychain key, and nothing is changed there.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if pending == nil, finished == nil, vaultData == nil, !browser.saved.isEmpty { exportCard }

            // Only while there is something to copy, which is only for a
            // person who had used the app this one comes from.
            if !legacy.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(legacy.count == 1
                                 ? "1 password was kept by \(Brand.name), the app this one comes from."
                                 : "\(legacy.count) passwords were kept by \(Brand.name), the app this one comes from.")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.ink)
                            Spacer(minLength: 0)
                            Pill(copying ? "Copying…" : "Copy to \(Brand.name)…") { copyLegacy() }
                                .disabled(copying)
                        }
                        Text("macOS asks for your login password to let each one go; Always Allow asks once. Nothing in \(Brand.name) is changed or removed.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                }
            }
        }
    }

    // MARK: - a passwords file

    private func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }

    private func summary(of result: PasswordImport.Result) -> String {
        var parts: [String] = []
        if result.added > 0 { parts.append(count(result.added, "new password", "new passwords")) }
        if result.updated > 0 { parts.append("\(result.updated) updated") }
        if result.skipped > 0 { parts.append("\(result.skipped) left as they were") }
        if result.failed > 0 { parts.append("\(result.failed) the keychain refused") }
        return parts.isEmpty ? "Nothing was added." : parts.joined(separator: " · ")
    }

    private func previewCard(_ plan: PasswordImport.Plan) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ready to bring in")
                    .font(Typeface.heading(15, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text("\(pendingFile?.lastPathComponent ?? "The file") looks like \(plan.source).")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                VStack(alignment: .leading, spacing: 4) {
                    line("\(plan.fresh.count)", "new")
                    if !plan.same.isEmpty { line("\(plan.same.count)", "already here, the same password") }
                    if !plan.different.isEmpty { line("\(plan.different.count)", "already here, with another password") }
                    if !plan.problems.isEmpty { line("\(plan.problems.count)", "can't be taken") }
                }
                if !plan.different.isEmpty {
                    HStack(spacing: 8) {
                        Text("Where a password is already here:")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink)
                        Picker("", selection: $choice) {
                            ForEach(PasswordImport.Duplicates.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                    }
                }
                if !plan.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(plan.problems.prefix(4).enumerated()), id: \.offset) { _, problem in
                            Text(problem.row > 0 ? "Row \(problem.row): \(problem.why)" : problem.why)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.muted)
                        }
                        if plan.problems.count > 4 {
                            Text("and \(plan.problems.count - 4) more")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Pill(writing ? "Bringing in…" : "Bring in", filled: true) { runImport(plan) }
                        .disabled(writing || plan.total == 0)
                    Pill("Cancel") { pending = nil; pendingFile = nil }
                        .disabled(writing)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func line(_ number: String, _ what: String) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .frame(minWidth: 34, alignment: .trailing)
            Text(what).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
        }
    }

    private func doneCard(_ result: PasswordImport.Result) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Brought in")
                    .font(Typeface.heading(15, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text(summary(of: result))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                Text(cameFromBackup
                     ? "\(Brand.name) keeps no copy of the backup file; it stays encrypted wherever you keep it."
                     : "The file still holds every password in plain text. \(Brand.name) keeps no copy of it: move it to the Trash now.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if pendingFile != nil, !trashed, !cameFromBackup {
                        Pill("Move the file to the Trash", filled: true) { moveToTrash() }
                    } else if trashed {
                        Text("\(pendingFile?.lastPathComponent ?? "The file") moved to the Trash").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    Pill("Done") { finished = nil; pendingFile = nil; trashed = false }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .json, .plainText] + [UTType(filenameExtension: PasswordExport.ext)].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.prompt = "Read"
        panel.message = "A passwords file another manager or browser exported (.csv, or Bitwarden's .json). Nothing is kept until you say so."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readFile(url)
    }

    private enum Read {
        case plan(PasswordImport.Plan)
        /// One of our own backups: it needs its passphrase first.
        case vault(Data)
        case bad
    }

    /// Reads and sorts it off the main thread; only the plan comes back.
    private func readFile(_ url: URL) {
        guard !reading, !writing else { return }
        reading = true
        finished = nil
        trashed = false
        openError = nil
        Task {
            let read: Read = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url) else { return .bad }
                if PasswordExport.isVault(data) { return .vault(data) }
                guard let parsed = PasswordImport.parse(data) else { return .bad }
                return .plan(PasswordImport.plan(parsed, kept: Vault.all(), secret: { Vault.secret(of: $0) }))
            }.value
            reading = false
            switch read {
            case .bad:
                browser.announce("That doesn't look like a passwords file")
            case .vault(let data):
                pendingFile = url
                vaultData = data
                openPass = ""
                tab = .bring
            case .plan(let plan):
                pendingFile = url
                pending = plan
                cameFromBackup = false
                choice = .skip
            }
        }
    }

    /// The passphrase is asked for a backup of ours; wrong, and the file stays
    /// shut.
    private func openVault() {
        guard let data = vaultData, !reading else { return }
        let passphrase = openPass
        reading = true
        openError = nil
        Task {
            let opened = await Task.detached(priority: .userInitiated) { () -> Result<PasswordImport.Plan, PasswordExport.Failure> in
                switch PasswordExport.open(data, passphrase: passphrase) {
                case .failure(let why): return .failure(why)
                case .success(let parsed):
                    return .success(PasswordImport.plan(parsed, kept: Vault.all(), secret: { Vault.secret(of: $0) }))
                }
            }.value
            reading = false
            switch opened {
            case .success(let plan):
                openPass = ""
                vaultData = nil
                pending = plan
                cameFromBackup = true
                choice = .skip
            case .failure(.wrongPassphrase):
                openError = "That passphrase doesn't open this file."
            case .failure(.tooNew):
                openError = "This backup was made by a newer \(Brand.name)."
            case .failure(.notAVault):
                openError = "This isn't a readable \(Brand.name) backup."
            }
        }
    }

    private var vaultCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("A \(Brand.name) backup")
                    .font(Typeface.heading(15, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text("\(pendingFile?.lastPathComponent ?? "This file") is encrypted. Type the passphrase it was made with.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                SecureField("Passphrase", text: $openPass)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit(openVault)
                if let openError {
                    errorLine(openError)
                }
                HStack(spacing: 8) {
                    Pill(reading ? "Opening…" : "Open", filled: true) { openVault() }
                        .disabled(reading || openPass.isEmpty)
                    Pill("Cancel") { vaultData = nil; pendingFile = nil; openPass = ""; openError = nil }
                        .disabled(reading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - taking them out

    private enum Out { case csv, backup }

    private var exportCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Take them out")
                    .font(Typeface.heading(15, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text("A backup is encrypted with a passphrase you choose, and only \(Brand.name) reads it back. A plain file opens in any other manager, but holds every password as readable text.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if askingBackup {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("Passphrase", text: $backupPass)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                        if backupPass.count < PasswordExport.shortest {
                            let more = PasswordExport.shortest - backupPass.count
                            Text("At least \(PasswordExport.shortest) characters (\(more) more)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.muted)
                        }
                        SecureField("Again", text: $backupAgain)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                        if !backupPass.isEmpty, !backupAgain.isEmpty, backupPass != backupAgain {
                            errorLine("The two don't match.")
                        } else {
                            Text("There is no way to open the backup without it: not even for \(Brand.name).")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.muted)
                        }
                        HStack(spacing: 8) {
                            Pill(exporting ? "Saving…" : "Save backup…", filled: true) {
                                // The fields are let go of once the file is
                                // written, not before: a save panel
                                // cancelled should not cost a retype.
                                export(.backup, passphrase: backupPass) {
                                    askingBackup = false; backupPass = ""; backupAgain = ""
                                }
                            }
                            .disabled(exporting || backupPass.count < PasswordExport.shortest || backupPass != backupAgain)
                            Pill("Cancel") { askingBackup = false; backupPass = ""; backupAgain = "" }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Pill("Encrypted backup…", filled: true) { askingBackup = true; exported = nil }
                            .disabled(exporting)
                        Pill("Plain file (CSV)…") { confirmPlain() }
                            .disabled(exporting)
                    }
                }
                if let exported {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(exportedLine(exported))
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Pill("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exported.url]) }
                            if exported.plain, !exportedTrashed {
                                Pill("Move it to the Trash") { trashExport(exported.url) }
                            } else if exportedTrashed {
                                Text("\(exported.url.lastPathComponent) moved to the Trash").font(.system(size: 12)).foregroundStyle(Palette.muted)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func exportedLine(_ done: Exported) -> String {
        let what = count(done.count, "password", "passwords")
        var line = done.plain
            ? "\(what) written to \(done.url.lastPathComponent), as plain text. Anyone who opens it can read them: move it to the Trash when you have used it."
            : "\(what) sealed in \(done.url.lastPathComponent). Keep the passphrase: it can't be recovered."
        if done.missed > 0 { line += " \(done.missed) couldn't be read from the keychain and are not in it." }
        return line
    }

    /// A plain file is the one way out that leaves passwords readable, so it
    /// asks first, and says so.
    private func confirmPlain() {
        Ask.sure(
            "Write every password as plain text?",
            detail: "The file holds each site, account and password readable by anything that opens it, and by anyone who gets the file. Use an encrypted backup unless another manager needs a CSV.",
            confirm: "Write the file…",
            returnCancels: true
        ) {
            exported = nil
            export(.csv, passphrase: "")
        }
    }

    /// Where to put it first, then the Mac's proof, then the read: nothing is
    /// held while a panel is up.
    private func export(_ kind: Out, passphrase: String, wrote: @escaping () -> Void = {}) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        switch kind {
        case .csv:
            panel.nameFieldStringValue = "\(Brand.name) passwords.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.message = "This file will hold every password as plain text."
        case .backup:
            panel.nameFieldStringValue = "\(Brand.name) passwords.\(PasswordExport.ext)"
            panel.allowedContentTypes = [UTType(filenameExtension: PasswordExport.ext)].compactMap { $0 }
            panel.message = "An encrypted backup, opened with its passphrase."
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        let all = browser.saved
        Vault.Unlock.ask("take your passwords out") { ok in
            guard ok else { exporting = false; return }
            Task {
                let made: (data: Data, count: Int)? = await Task.detached(priority: .userInitiated) {
                    let items = all.compactMap { Vault.item(of: $0) }
                    let data: Data?
                    switch kind {
                    case .csv: data = PasswordExport.csv(items).data(using: .utf8)
                    case .backup: data = PasswordExport.seal(items, passphrase: passphrase)
                    }
                    return data.map { ($0, items.count) }
                }.value
                exporting = false
                guard let made else { browser.announce("Couldn't make the file"); return }
                do {
                    try made.data.write(to: url, options: .atomic)
                    // Only the one who made it reads it.
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    exportedTrashed = false
                    exported = Exported(url: url, plain: kind == .csv, count: made.count, missed: all.count - made.count)
                    wrote()
                } catch {
                    browser.announce("Couldn't save the file")
                }
            }
        }
    }

    private func trashExport(_ url: URL) {
        NSWorkspace.shared.recycle([url]) { _, error in
            DispatchQueue.main.async {
                if error == nil { exportedTrashed = true } else { browser.announce("Couldn't move it to the Trash") }
            }
        }
    }

    private func runImport(_ plan: PasswordImport.Plan) {
        writing = true
        let chosen = choice
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                PasswordImport.commit(plan, duplicates: chosen) { candidate, keep in
                    Vault.save(host: candidate.host, user: candidate.user, password: candidate.password, clear: candidate.clear,
                               extras: keep ? nil : candidate.extras)
                }
            }.value
            writing = false
            pending = nil
            finished = result
            browser.relist()
        }
    }

    private func moveToTrash() {
        guard let url = pendingFile else { return }
        NSWorkspace.shared.recycle([url]) { _, error in
            DispatchQueue.main.async {
                if error == nil { trashed = true } else { browser.announce("Couldn't move it to the Trash") }
            }
        }
    }

    private func refreshLegacy() async {
        legacy = await Task.detached(priority: .utility) { Vault.legacy() }.value
    }

    /// The copy, read item by item off the main thread: each read may put up
    /// the system's own prompt, and a wait on one is not a frozen window.
    private func copyLegacy() {
        let items = legacy
        copying = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { Vault.copyLegacy(items) }.value
            copying = false
            browser.relist()
            await refreshLegacy()
            let done = result.copied == 1 ? "1 password" : "\(result.copied) passwords"
            browser.announce(result.skipped == 0
                             ? "Copied \(done) from \(Brand.name)"
                             : "Copied \(done) from \(Brand.name), \(result.skipped) not allowed — try again to copy those")
        }
    }

    // MARK: - one row of the list

    private struct Row: View {
        let login: Kept
        let picked: Bool
        /// The last health check found something to say about it.
        let flagged: Bool
        let focus: FocusState<String?>.Binding
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Mark(icon: Favicons.shared.cached(login.host), letter: login.host.first.map { String($0).uppercased() } ?? "•", size: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(login.host)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(login.user.isEmpty ? "No username" : login.user)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if flagged {
                        Circle().fill(Palette.accent).frame(width: 6, height: 6)
                            .help("The Health tab has something to say about this one")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The pick is a neutral wash with a thin bar of the accent,
                // not a tint of it: the same quiet mark Settings uses.
                .background(picked ? Palette.wash : (hovering ? Palette.hover : .clear))
                .overlay(alignment: .leading) {
                    if picked { Rectangle().fill(Palette.accent).frame(width: 2.5) }
                }
                .overlay(
                    Rectangle()
                        .strokeBorder(Palette.accent, lineWidth: 1.5)
                        .opacity(focus.wrappedValue == login.id ? 1 : 0)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused(focus, equals: login.id)
            .focusEffectDisabled()
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .accessibilityLabel("\(login.host), \(login.user.isEmpty ? "No username" : login.user)")
            .accessibilityAddTraits(picked ? .isSelected : [])
        }
    }

    // MARK: - the one picked

    /// One account: what it is, its password as dots, and what to do with
    /// it. Show asks the Mac who you are first (once for five minutes), and is
    /// when the notes and the rest are read; until then the item's value has
    /// not been touched.
    private struct Detail: View {
        let login: Kept
        let edit: (Item) -> Void
        let copy: () -> Void
        let announce: (String) -> Void
        let forget: () -> Void

        /// The whole item, from the moment it is shown to the moment it is
        /// hidden again. The only place it is held, and only while on screen.
        @State private var item: Item?
        @State private var hide: DispatchWorkItem?

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Mark(icon: Favicons.shared.cached(login.host), letter: login.host.first.map { String($0).uppercased() } ?? "•", size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item?.extras.title.flatMap { $0.isEmpty ? nil : $0 } ?? login.host)
                            .font(Typeface.heading(19, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        if item?.extras.title.map({ !$0.isEmpty }) == true {
                            Text(login.host).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                        }
                    }
                    Spacer(minLength: 0)
                }

                field("Username") {
                    Text(login.user.isEmpty ? "No username" : login.user)
                        .font(.system(size: 13))
                        .foregroundStyle(login.user.isEmpty ? Palette.muted : Palette.ink)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    if !login.user.isEmpty {
                        Quick("Copy") {
                            KeptClipboard.put(login.user, clearAfter: nil)
                            announce("Username copied")
                        }
                    }
                }

                field("Password") {
                    // Ten dots whatever it is: a count that changed with it
                    // told anyone looking over a shoulder how long it was.
                    Text(item.map(\.password) ?? String(repeating: "•", count: 10))
                        .font(.system(size: item == nil ? 11 : 13, design: .monospaced))
                        .foregroundStyle(item == nil ? Palette.muted : Palette.ink)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Quick(item == nil ? "Show" : "Hide") { item == nil ? reveal() : conceal() }
                    if item != nil {
                        Text("Hides in 15s").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Quick("Copy", act: copy)
                }

                if let item {
                    if let urls = item.extras.urls, !urls.isEmpty {
                        field("Also used on") {
                            Text(urls.joined(separator: "\n")).font(.system(size: 12.5)).foregroundStyle(Palette.ink).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                    if let notes = item.extras.notes, !notes.isEmpty {
                        field("Notes") {
                            Text(notes).font(.system(size: 12.5)).foregroundStyle(Palette.ink).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                    if let text = item.extras.totp, !text.isEmpty {
                        field("Verification code") {
                            if let key = TOTP.key(from: text) {
                                CodeLine(key: key, announce: announce)
                            } else {
                                Text("The setup key isn't one this can read").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Pill("Edit") { editNow() }
                    Spacer(minLength: 0)
                    Pill("Remove", tint: Tone.remove, action: forget)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onDisappear { conceal() }
        }

        private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                HStack(alignment: .firstTextBaseline, spacing: 6) { content() }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }

        private func reveal() {
            load { loaded in
                item = loaded
                // Long enough to read or type across, and not a minute more.
                let work = DispatchWorkItem { conceal() }
                hide?.cancel()
                hide = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
            }
        }

        private func editNow() {
            if let item { edit(item); return }
            load(edit)
        }

        /// Read after the Mac has said who this is, not before.
        private func load(_ then: @escaping (Item) -> Void) {
            Vault.Unlock.ask("show the password for \(login.host)") { ok in
                guard ok, let loaded = Vault.item(of: login) else { return }
                then(loaded)
            }
        }

        /// Hidden again, and the secret with it.
        private func conceal() {
            hide?.cancel()
            item = nil
        }
    }

    // MARK: - adding and editing

    /// Typing one in by hand, or changing one. For a change the whole item is
    /// already in hand (it was read when Edit was pressed, after the Mac said
    /// who you are).
    private struct EditForm: View {
        @ObservedObject var browser: Browser
        let editing: Editing
        /// Whether the fields differ from what was opened (or, for a new one,
        /// are not empty), for the panel to ask before letting them go.
        @Binding var dirty: Bool
        let done: (Kept?) -> Void

        @State private var site = ""
        @State private var user = ""
        @State private var password = ""
        @State private var title = ""
        @State private var notes = ""
        @State private var code = ""
        @State private var urls = ""
        @State private var showing = false
        @State private var options = PasswordGenerator.Options.saved
        @FocusState private var focus: Int?

        private var existing: Item? { if case .existing(let item) = editing { item } else { nil } }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(existing == nil ? "New password" : "Edit")
                    .font(Typeface.heading(17, weight: .medium))
                    .foregroundStyle(Palette.ink)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        row("Site") { TextField("example.com", text: $site).focused($focus, equals: 0) }
                        row("Username") { TextField("", text: $user).focused($focus, equals: 1) }
                        row("Password") {
                            Group {
                                if showing { TextField("", text: $password) } else { SecureField("", text: $password) }
                            }
                            .font(.system(size: 12.5, design: .monospaced))
                            .focused($focus, equals: 2)
                            Quick(showing ? "Hide" : "Show") { showing.toggle() }
                        }
                        generator
                        row("Name (optional)") { TextField("", text: $title) }
                        row("Verification code setup key (optional)") {
                            SecureField("otpauth:// link or setup key", text: $code)
                        }
                        row("Also used on (optional, one per line)", tall: true) {
                            TextEditor(text: $urls).scrollContentBackground(.hidden).frame(height: 44)
                        }
                        row("Notes (optional)", tall: true) {
                            TextEditor(text: $notes).scrollContentBackground(.hidden).frame(height: 64)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Pill("Cancel") { if isDirty { confirmDiscard { done(nil) } } else { done(nil) } }
                    Spacer(minLength: 0)
                    Pill("Save", filled: true, action: keep)
                        .disabled(Vault.host(of: site).isEmpty || password.isEmpty)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                if let item = existing {
                    site = item.host; user = item.user; password = item.password
                    title = item.extras.title ?? ""; notes = item.extras.notes ?? ""
                    code = item.extras.totp ?? ""; urls = (item.extras.urls ?? []).joined(separator: "\n")
                }
                focus = existing == nil ? 0 : 2
            }
            .onChange(of: isDirty) { _, now in dirty = now }
            .onDisappear { dirty = false }
        }

        private var isDirty: Bool {
            guard let item = existing else {
                return ![site, user, password, title, notes, code, urls].allSatisfy(\.isEmpty)
            }
            return site != item.host || user != item.user || password != item.password
                || title != (item.extras.title ?? "") || notes != (item.extras.notes ?? "")
                || code != (item.extras.totp ?? "") || urls != (item.extras.urls ?? []).joined(separator: "\n")
        }

        /// A new password, made here: random characters or a few plain words,
        /// as strong as the bar says. Generate puts it in the box above and
        /// shows it, so it can be read before it is kept.
        private var generator: some View {
            // Two lines: the pieces together are wider than the card is.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Picker("", selection: $options.style) {
                        ForEach(PasswordGenerator.Style.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    Spacer(minLength: 0)
                    Pill("Generate") {
                        password = PasswordGenerator.make(options)
                        showing = true
                    }
                }
                HStack(spacing: 10) {
                    if options.style == .random {
                        Stepper("Length \(options.length)", value: $options.length, in: PasswordGenerator.Options.lengths)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize()
                        Toggle("Symbols", isOn: $options.symbols)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                    } else {
                        Stepper("Words \(options.words)", value: $options.words, in: PasswordGenerator.Options.wordCounts)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                    Text(PasswordGenerator.strength(PasswordGenerator.bits(options)))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
            }
            .onChange(of: options) { _, new in PasswordGenerator.Options.saved = new }
        }

        private func row<Content: View>(_ label: String, tall: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.muted)
                HStack(spacing: 6) { content().textFieldStyle(.plain) }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, tall ? 4 : 7)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }

        private func keep() {
            let host = Vault.host(of: site)
            guard !host.isEmpty, !password.isEmpty else { return }
            func clean(_ text: String) -> String? {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            let others = urls.split(whereSeparator: \.isNewline).compactMap { clean(String($0)) }
            let extras = Extras(title: clean(title), notes: clean(notes), totp: clean(code),
                                urls: others.isEmpty ? nil : others,
                            changed: Extras.changedDate(existing: existing, newPassword: password))
            let item = Item(host: host, user: user.trimmingCharacters(in: .whitespaces), password: password, extras: extras,
                            used: existing?.used, clear: existing?.clear ?? false)
            let old = existing.map { Kept(host: $0.host, user: $0.user, used: $0.used, clear: $0.clear) }
            browser.keep(item, replacing: old)
            done(Kept(host: item.host, user: item.user, used: item.used, clear: item.clear))
        }
    }
}
