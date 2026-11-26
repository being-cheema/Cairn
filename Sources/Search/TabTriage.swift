import SwiftUI

// Tabs › Triage Tabs…: the tabs of this space put in groups by what they are
// about, the ones open twice pointed out, and a group archived with one click
// or attached to a message for Claude.
//
// The grouping is done on this Mac from titles and site names alone, with
// Apple's sentence vectors (MemoryIndex) where there is a model, by site
// where there isn't. Pins, private tabs and agents' tabs are left out of it.
// Nothing goes to Claude from here: its button fills the panel's box, and
// sending is your Send.

enum Triage {
    struct Item: Equatable {
        let id: UUID
        let title: String
        let url: URL
        /// Nil with no sentence model: grouped by site alone.
        var vector: [Double]?

        var site: String {
            let host = url.host()?.lowercased() ?? url.absoluteString
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    struct Cluster: Equatable, Identifiable {
        var name: String
        var items: [Item]
        var id: UUID { items.first?.id ?? UUID() }
    }

    /// How close two tabs' words must be to be about one thing.
    static let alike = 0.6

    /// Each tab with the first group that has one of its site, or one whose
    /// words are close enough to its own; else a group of its own. Biggest
    /// first.
    static func clusters(_ items: [Item]) -> [Cluster] {
        var groups: [[Item]] = []
        for item in items {
            let at = groups.firstIndex { group in group.contains { $0.site == item.site } }
                ?? groups.firstIndex { group in
                    guard let mine = item.vector, let first = group.first?.vector else { return false }
                    return MemoryIndex.closeness(mine, first) >= alike
                }
            if let at { groups[at].append(item) } else { groups.append([item]) }
        }
        return groups.enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map { Cluster(name: name($0.element), items: $0.element) }
    }

    private static func name(_ group: [Item]) -> String {
        var counts: [String: Int] = [:]
        for item in group { counts[item.site, default: 0] += 1 }
        let sites = group.map(\.site)
        let main = sites.max { counts[$0, default: 0] < counts[$1, default: 0] } ?? ""
        return counts.count == 1 ? main : "\(main) and \(counts.count - 1) more"
    }

    /// Tabs at one and the same address, to the last character: an address
    /// that differs only after its # can be another page of the same site.
    static func duplicates(_ items: [Item]) -> [[Item]] {
        var order: [String] = []
        var found: [String: [Item]] = [:]
        for item in items {
            let key = item.url.absoluteString
            if found[key] == nil { order.append(key) }
            found[key, default: []].append(item)
        }
        return order.compactMap { found[$0] }.filter { $0.count > 1 }
    }

    /// What the panel's box is given for a group.
    static let synthesis = "Read the tabs I attached and bring them together: what they say, where they agree and differ, and what is worth keeping."
}

extension Browser {
    /// The tabs triage looks at: this space's own web pages.
    var triageTabs: [Tab] {
        tabs.filter { tab in
            guard !tab.shy, !tab.bench, !tab.agent, tab.pin == nil, let url = tab.address else { return false }
            return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        }
    }

    /// Closed, and kept in Archived Tabs to be had again.
    func triageArchive(_ ids: [Tab.ID]) {
        for tab in triageTabs where ids.contains(tab.id) {
            archive(tab)
            close(tab)
        }
    }

    /// Of tabs open twice or more, the one in front is kept, or else the one
    /// looked at last; the rest are archived.
    func triageCloseExtras(_ ids: [Tab.ID]) {
        let same = triageTabs.filter { ids.contains($0.id) }
        guard same.count > 1,
              let keep = same.first(where: { $0.id == activeID }) ?? same.max(by: { $0.touched < $1.touched }) else { return }
        triageArchive(same.filter { $0.id != keep.id }.map(\.id))
    }

    /// The group's tabs named for the next message in the Claude panel, as
    /// "@" would name them, and a message written for you to send or change.
    /// A message holds so many (Mentions.most); returns how many were left.
    @discardableResult
    func triageAskClaude(_ ids: [Tab.ID]) -> Int {
        let named = triageTabs.filter { ids.contains($0.id) && Mentions.mayName($0) }
        claude.mentions = named.prefix(Mentions.most).map { .tab($0.id, label: Mentions.label($0)) }
        if claude.draft.isEmpty { claude.draft = Triage.synthesis }
        if !(sidePanelShown && sidePanel == .claude) { toggleClaudePanel() }
        return max(0, named.count - Mentions.most)
    }
}

struct TabTriageSheet: View {
    @ObservedObject var browser: Browser
    let close: () -> Void

    @State private var clusters: [Triage.Cluster] = []
    @State private var doubles: [[Triage.Item]] = []
    @State private var looked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Triage Tabs").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            Text("This space's tabs, grouped on this Mac by their titles and sites. Pins and private tabs aren't listed. Archived tabs are in History › Archived Tabs.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if looked, clusters.isEmpty {
                        Text("No tabs to sort.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    ForEach(Array(doubles.enumerated()), id: \.offset) { _, same in
                        HStack(spacing: 8) {
                            Image(systemName: "square.on.square").font(.system(size: 11)).foregroundStyle(.orange)
                            Text(verbatim: "Open \(same.count) times: \(same[0].title)")
                                .font(.system(size: 12)).foregroundStyle(Palette.ink).lineLimit(1)
                            Spacer(minLength: 8)
                            Quick("Keep One") {
                                browser.triageCloseExtras(same.map(\.id))
                                look()
                            }
                        }
                        .padding(9)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    ForEach(clusters) { cluster in group(cluster) }
                }
            }
        }
        .padding(18)
        .frame(width: 520, height: 520)
        .background(Palette.ground)
        .onAppear(perform: look)
    }

    private func group(_ cluster: Triage.Cluster) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(verbatim: cluster.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: 8)
                Quick("Ask Claude") {
                    let left = browser.triageAskClaude(cluster.items.map(\.id))
                    if left > 0 { browser.announce("The first \(Mentions.most) tabs are attached; a message holds no more") }
                    close()
                }
                .help("Attaches these tabs in the Claude panel. Nothing is sent until you press Send.")
                Quick("Archive", tint: Palette.muted) {
                    browser.triageArchive(cluster.items.map(\.id))
                    look()
                }
            }
            ForEach(cluster.items, id: \.id) { item in
                Button {
                    if let tab = browser.tabs.first(where: { $0.id == item.id }) { browser.select(tab) }
                    close()
                } label: {
                    // The page's own title: words to show, nothing more.
                    Text(verbatim: item.title)
                        .font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func look() {
        let items = browser.triageTabs.compactMap { tab -> Triage.Item? in
            guard let url = tab.address else { return nil }
            return Triage.Item(id: tab.id, title: tab.label, url: url)
        }
        doubles = Triage.duplicates(items)
        // The model is loaded and asked away from the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let grouped = Triage.clusters(items.map { item in
                var item = item
                item.vector = MemoryIndex.sentenceVector(item.title + ". " + item.site)
                return item
            })
            DispatchQueue.main.async {
                clusters = grouped
                looked = true
            }
        }
    }
}
