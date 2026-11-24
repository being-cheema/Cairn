import SwiftUI

/// Every password kept: a list on the left, the one picked on the right. The
/// same rule as ever: a password is never shown until you have proved you are
/// you (Vault.Unlock), and never for longer than it takes to read it.
struct PasswordsPanel: View {
    @ObservedObject var browser: Browser

    enum Tab: String, CaseIterable, Identifiable {
        case all = "All"
        case codes = "Codes"
        case bring = "Bring in"
        var id: String { rawValue }
    }

    /// What the right side is doing besides showing one.
    enum Editing: Equatable {
        case new
        case existing(Item)
    }

    @FocusState private var hunting: Bool
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
        .onChange(of: tab) { _, now in if now == .codes { loadCodes() } else { coded = [] } }
        .animation(Motion.settle, value: tab)
        .animation(Motion.settle, value: editing)
        .onAppear { hunting = true }
        .task { await refreshLegacy() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { tab = .bring; readFile(url) }
            }
            return true
        }
        .onChange(of: browser.hunting) { _, _ in
            // The one picked fell out of the search: nothing is picked.
            if let selected, !rows.contains(where: { $0.id == selected }) { self.selected = nil; editing = nil }
        }
    }

    // MARK: - the tabs

    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach(Tab.allCases) { each in
                Button { tab = each } label: {
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
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - all of them

    private var all: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Hunt(text: $browser.hunting, prompt: "Search sites and accounts", focus: $hunting)
                    Pill("Add", filled: true) { selected = nil; editing = .new }
                }
                list
            }
            .frame(width: 300)

            Card { detail }
                .frame(maxWidth: .infinity)
        }
        .frame(height: 440)
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
                        Row(login: login, picked: selected == login.id) {
                            editing = nil
                            selected = login.id
                        }
                    }
                }
                .padding(.bottom, 2)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let editing {
            EditForm(browser: browser, editing: editing) { saved in
                self.editing = nil
                if let saved { selected = saved.id }
            }
            .id(editing == .new ? "new" : "edit-\(selected ?? "")")
        } else if let login = picked {
            Detail(
                login: login,
                edit: { item in editing = .existing(item) },
                copy: { browser.copy(login) },
                forget: { browser.forget(login); selected = nil }
            )
            .id(login.id)
        } else {
            VStack {
                Spacer()
                Text(browser.saved.isEmpty ? "Add a password, or bring yours in." : "Pick one to see it.")
                    .font(Typeface.heading(14))
                    .foregroundStyle(Palette.muted)
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

    @ViewBuilder
    private var codesTab: some View {
        if coded.isEmpty {
            Card {
                Nothing(loadingCodes ? "Reading…" : "No verification codes yet. Add a setup key to a password (Edit), or bring in a file that has them.",
                        art: "approval")
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
                            CodeLine(key: item.key)
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
        let all = browser.saved
        Vault.Unlock.ask("show your verification codes") { ok in
            guard ok else { loadingCodes = false; tab = .all; return }
            Task {
                let found: [CodeItem] = await Task.detached(priority: .userInitiated) {
                    all.compactMap { kept -> CodeItem? in
                        guard let item = Vault.item(of: kept), let text = item.extras.totp, let key = TOTP.key(from: text) else { return nil }
                        let title = item.extras.title.flatMap { $0.isEmpty ? nil : $0 } ?? kept.host
                        return CodeItem(id: kept.id, name: title, detail: kept.user.isEmpty ? kept.host : kept.user, key: key)
                    }
                }.value
                loadingCodes = false
                if tab == .codes { coded = found }
            }
        }
    }

    /// The six digits now, how long they last, and Copy. Ticks every second;
    /// the key is the only thing held.
    private struct CodeLine: View {
        let key: TOTP.Key

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
                    Quick("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                }
            }
        }
    }

    // MARK: - bringing them in

    private var bring: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let finished {
                doneCard(finished)
            } else if let plan = pending {
                previewCard(plan)
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("From another manager or browser")
                            .font(Typeface.heading(15, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        Text("Drop a passwords file here, or pick one. The Passwords app, Safari, Chrome, Edge, Brave, Firefox, Bitwarden, 1Password, LastPass, KeePass and Dashlane all export one; its kind is worked out from its columns. You see what it would do before anything is kept.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Pill(reading ? "Reading…" : "Passwords file…", filled: true) { chooseFile() }
                                .disabled(reading)
                            Pill("Another browser…") { browser.lead(to: InternalPage(.importing)) }
                            Pill("Bookmarks and history file…") { browser.importFile() }
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

            // What the list shows, all of it or what the search leaves: never
            // more than can be seen (Browser.forgetShown).
            let shown = rows.count
            if shown > 0 {
                HStack {
                    Spacer(minLength: 0)
                    Pill(browser.hunting.trimmingCharacters(in: .whitespaces).isEmpty ? "Remove All…" : "Remove \(shown)…", tint: .red.opacity(0.75)) {
                        browser.forgetShown()
                    }
                    .disabled(browser.forgetting)
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
                                .foregroundStyle(Palette.faint)
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
                Text("The file still holds every password in plain text. \(Brand.name) keeps no copy of it: move it to the Trash now.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if pendingFile != nil, !trashed {
                        Pill("Move the file to the Trash", filled: true) { moveToTrash() }
                    } else if trashed {
                        Text("In the Trash").font(.system(size: 12)).foregroundStyle(Palette.muted)
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
        panel.allowedContentTypes = [.commaSeparatedText, .json, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Read"
        panel.message = "A passwords file another manager or browser exported (.csv, or Bitwarden's .json). Nothing is kept until you say so."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readFile(url)
    }

    /// Reads and sorts it off the main thread; only the plan comes back.
    private func readFile(_ url: URL) {
        guard !reading, !writing else { return }
        reading = true
        finished = nil
        trashed = false
        Task {
            let plan: PasswordImport.Plan? = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url), let parsed = PasswordImport.parse(data) else { return nil }
                return PasswordImport.plan(parsed, kept: Vault.all(), secret: { Vault.secret(of: $0) })
            }.value
            reading = false
            guard let plan else {
                browser.announce("That doesn't look like a passwords file")
                return
            }
            pendingFile = url
            pending = plan
            choice = .skip
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
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(picked ? Palette.accent.opacity(0.12) : (hovering ? Palette.hover : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: pick)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
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
                        .foregroundStyle(login.user.isEmpty ? Palette.faint : Palette.ink)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    if !login.user.isEmpty { Quick("Copy") { copyText(login.user) } }
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
                                CodeLine(key: key)
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
                    Pill("Remove", tint: .red.opacity(0.75), action: forget)
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

        private func copyText(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
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
                    Pill("Cancel") { done(nil) }
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
        }

        /// A new password, made here: random characters or a few plain words,
        /// as strong as the bar says. Generate puts it in the box above and
        /// shows it, so it can be read before it is kept.
        private var generator: some View {
            HStack(spacing: 10) {
                Picker("", selection: $options.style) {
                    ForEach(PasswordGenerator.Style.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
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
                Pill("Generate") {
                    password = PasswordGenerator.make(options)
                    showing = true
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
                                urls: others.isEmpty ? nil : others, changed: Date())
            let item = Item(host: host, user: user.trimmingCharacters(in: .whitespaces), password: password, extras: extras,
                            used: existing?.used, clear: existing?.clear ?? false)
            let old = existing.map { Kept(host: $0.host, user: $0.user, used: $0.used, clear: $0.clear) }
            browser.keep(item, replacing: old)
            done(Kept(host: item.host, user: item.user, used: item.used, clear: item.clear))
        }
    }
}
