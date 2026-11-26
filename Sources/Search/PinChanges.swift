import AppKit
import SwiftUI
import WebKit

// What changed on a pinned page since you last looked: a small dot on the
// pin, and See Changes in its menu.
//
// Off until switched on (Settings › Privacy › Show what changed on pinned
// pages), since it writes the words of those pages to disk, as you see them,
// signed in. Only a pin on the very page it was pinned at; never a private
// tab, an agent's or one in a store that keeps nothing; never a site closed
// to agents (VaultedSites). What is kept is PageWords's to say. Switching it
// off, clearing all history, unpinning a page or closing its site to agents
// deletes what was kept.

struct PinSnapshot: Codable, Equatable {
    /// The site, so a site closed later takes its snapshots with it.
    let host: String
    /// The words as you last saw them.
    var text: String
    var hash: String
    /// The words as they are now, when they changed and you haven't looked.
    var newer: String?

    /// What a load of the page leaves kept: the first is what later ones are
    /// held against; a change is held until you look; a page gone back to
    /// what you saw is no change.
    static func after(_ old: PinSnapshot?, loading said: String, host: String) -> PinSnapshot? {
        let text = PageWords.kept(said)
        // Nothing to read is a page that hasn't come, not an empty one.
        guard !PageWords.lines(text).isEmpty else { return old }
        guard var now = old else { return PinSnapshot(host: host, text: text, hash: PageWords.hash(text)) }
        now.newer = PageWords.changed(from: now.text, to: text) ? text : nil
        return now
    }

    /// Looked at: what is there now is what you have seen.
    var seen: PinSnapshot {
        guard let newer else { return self }
        return PinSnapshot(host: host, text: newer, hash: PageWords.hash(newer))
    }
}

@MainActor
final class PinChanges: ObservableObject {
    static let shared = PinChanges()
    static let key = "pins.changes"

    private let folder: URL
    /// The pages changed since you looked, by `name(of:)`.
    @Published private(set) var changed: Set<String> = []

    init(folder: URL = Store.file("PinSnapshots")) {
        self.folder = folder
        changed = Set(names().filter { load($0)?.newer != nil })
    }

    private var on: Bool { Store.settings.bool(forKey: Self.key) }

    /// One page, whatever part of it was jumped to; its file's name says
    /// nothing of the address.
    static func name(of url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return PageWords.hash(parts?.string ?? url.absoluteString)
    }

    /// Whether this load of this tab may be kept.
    func may(_ tab: Tab) -> Bool {
        guard on, tab.pin != nil, !tab.shy, !tab.agent, !tab.bench, tab.store.isPersistent,
              let url = tab.pageAddress, let home = tab.home,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !VaultedSites.blocks(url, in: VaultedSites.current) else { return false }
        return Self.name(of: url) == Self.name(of: home)
    }

    /// A pin's page has loaded. Read a moment later, once it has drawn what
    /// it draws after loading, if it is still the same page.
    func loaded(_ tab: Tab, after delay: TimeInterval = 2) {
        guard may(tab), let url = tab.pageAddress else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak tab] in
            guard let self, let tab, may(tab), tab.pageAddress == url, !tab.loading, let web = tab.built else { return }
            PageMarkdown.read(web, links: false, most: PageWords.longest) { [weak self, weak tab] page in
                // Asked again: switched off or closed to agents meanwhile.
                guard let self, let tab, let page, may(tab), tab.pageAddress == url else { return }
                keep(page.markdown, for: url)
            }
        }
    }

    func keep(_ said: String, for url: URL) {
        guard on, let host = VaultedSites.host(of: url) else { return }
        let name = Self.name(of: url)
        let old = load(name)
        guard let now = PinSnapshot.after(old, loading: said, host: host) else { return }
        if now != old { save(now, as: name) }
        if now.newer != nil { changed.insert(name) } else { changed.remove(name) }
    }

    func hasChanges(_ tab: Tab) -> Bool {
        guard tab.pin != nil, !tab.shy, let home = tab.home else { return false }
        return changed.contains(Self.name(of: home))
    }

    func snapshot(for url: URL) -> PinSnapshot? { load(Self.name(of: url)) }

    /// See Changes was closed.
    func markSeen(_ url: URL) {
        let name = Self.name(of: url)
        if let kept = load(name) { save(kept.seen, as: name) }
        changed.remove(name)
    }

    func forget(_ url: URL) {
        let name = Self.name(of: url)
        try? FileManager.default.removeItem(at: file(name))
        changed.remove(name)
    }

    func forgetAll() {
        try? FileManager.default.removeItem(at: folder)
        changed = []
    }

    /// Sites just closed to agents: what was kept of them goes.
    func forget(sites: Set<String>) {
        guard !sites.isEmpty else { return }
        for name in names() {
            guard let kept = load(name), sites.contains(where: { VaultedSites.covers($0, kept.host) }) else { continue }
            try? FileManager.default.removeItem(at: file(name))
            changed.remove(name)
        }
    }

    // MARK: - files

    private func file(_ name: String) -> URL { folder.appendingPathComponent("\(name).json") }

    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
    }

    private func load(_ name: String) -> PinSnapshot? {
        (try? Data(contentsOf: file(name))).flatMap { try? JSONDecoder().decode(PinSnapshot.self, from: $0) }
    }

    private func save(_ snapshot: PinSnapshot, as name: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        PageWords.write(data, to: file(name))
    }
}

// MARK: - what shows

/// The dot on a pin whose page changed since you looked.
struct PinChangeDot: ViewModifier {
    let tab: Tab
    @ObservedObject private var changes = PinChanges.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if changes.hasChanges(tab) {
                Circle()
                    .fill(Palette.accent)
                    .frame(width: 5, height: 5)
                    .offset(x: 2, y: 2)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Changed since you looked")
            }
        }
    }
}

extension View {
    func pinChangeDot(_ tab: Tab) -> some View { modifier(PinChangeDot(tab: tab)) }
}

/// See Changes, as a sheet over the window: what was taken out and put in.
struct PinChangesSheet: View {
    let title: String
    let lines: [PageWords.Line]
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Text("Since you last looked. Taken out is struck through; put in is marked.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560, height: 440)
    }

    /// The page's words, as plain words: no link, no Markdown drawn.
    private func row(_ line: PageWords.Line) -> some View {
        let mark = line.kind == .added ? "+ " : line.kind == .removed ? "− " : "  "
        return Text(verbatim: line.kind == .gap ? line.text : mark + line.text)
            .font(.system(size: 12))
            .strikethrough(line.kind == .removed)
            .foregroundStyle(line.kind == .added || line.kind == .removed ? Palette.ink : Palette.muted)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(line.kind == .added ? Palette.accent.opacity(0.16) : Color.clear)
    }
}

extension Browser {
    func seeChanges(_ tab: Tab) {
        guard let home = tab.home, let kept = PinChanges.shared.snapshot(for: home), let newer = kept.newer,
              let window, window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let view = PinChangesSheet(title: tab.label, lines: PageWords.difference(from: kept.text, to: newer)) {
            [weak window, weak sheet] in
            if let window, let sheet { window.endSheet(sheet) }
            PinChanges.shared.markSeen(home)
        }
        sheet.contentViewController = NSHostingController(rootView: view)
        window.beginSheet(sheet)
    }
}
