import SwiftUI

// How you got to the tabs you have open: which one each was opened from,
// drawn as trees (View › Tab Journey, ⌥⌘G), with a branch moved to a Space
// of its own or its dead ends archived in a click.
//
// What is remembered is only a tab's number and the number of the one whose
// link or page opened it, in memory, for this run: no address, no title,
// nothing written. After a relaunch every tab starts a tree of its own.
// Private tabs are neither remembered nor drawn.
//
// It is not Tab.opener: that one lets a page close its tab and a swipe back
// close it, and a link you ⌘-clicked is given neither.

/// Which tab each was opened from. Links through a tab since closed are
/// kept, so its children stay in their tree.
@MainActor
final class JourneyLog {
    static let shared = JourneyLog()
    private(set) var parents: [Tab.ID: Tab.ID] = [:]

    func opened(_ tab: Tab, from source: Tab) {
        guard !tab.shy, !source.shy, tab.id != source.id else { return }
        parents[tab.id] = source.id
    }

    /// A tab swapped for a new one where it stood (Browser.replace).
    func replaced(_ old: Tab.ID, with new: Tab.ID) {
        if let parent = parents[old] { parents[new] = parent }
        for (child, parent) in parents where parent == old { parents[child] = new }
    }
}

/// The trees, laid out. Pure.
enum JourneyTree {
    struct Placed: Equatable {
        let id: UUID
        /// The nearest tab it came from that is still open.
        let parent: UUID?
        /// How many steps from its tree's first tab: its column.
        let depth: Int
        /// Its line. A parent shares its first child's.
        let row: Int
        let children: [UUID]
    }

    /// `open` in the row's order; `parents` may pass through tabs closed
    /// since. The result is in the order drawn: each tree, depth first.
    static func layout(_ open: [UUID], parents: [UUID: UUID]) -> [Placed] {
        let here = Set(open)
        func above(_ id: UUID) -> UUID? {
            var seen: Set<UUID> = [id]
            var next = parents[id]
            while let candidate = next, seen.insert(candidate).inserted {
                if here.contains(candidate) { return candidate }
                next = parents[candidate]
            }
            return nil
        }
        var up: [UUID: UUID] = [:]
        for id in open { up[id] = above(id) }
        // Two tabs each said to come from the other (a swap can make it so)
        // would be in no tree: the first in the row starts one.
        for id in open {
            var seen: Set<UUID> = []
            var at: UUID? = id
            while let each = at {
                if !seen.insert(each).inserted { up[each] = nil; break }
                at = up[each]
            }
        }
        var children: [UUID: [UUID]] = [:]
        for id in open { if let parent = up[id] { children[parent, default: []].append(id) } }

        var out: [Placed] = []
        var row = 0
        func place(_ id: UUID, _ depth: Int) {
            let below = children[id] ?? []
            out.append(Placed(id: id, parent: up[id], depth: depth, row: row, children: below))
            if below.isEmpty { row += 1 }
            for child in below { place(child, depth + 1) }
        }
        for id in open where up[id] == nil { place(id, 0) }
        return out
    }

    /// A tab and everything that came from it, in the order drawn.
    static func branch(_ id: UUID, in placed: [Placed]) -> [UUID] {
        let byID = Dictionary(placed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [UUID] = []
        func take(_ id: UUID) {
            guard let node = byID[id] else { return }
            out.append(id)
            node.children.forEach(take)
        }
        take(id)
        return out
    }

    /// The ends that went nowhere: opened from another tab, nothing opened
    /// from them, not the one on screen, and nothing keeping them open
    /// (`mayClose`: what tabs closing themselves go by).
    static func deadEnds(_ placed: [Placed], current: UUID?, mayClose: (UUID) -> Bool) -> [UUID] {
        placed.filter { $0.parent != nil && $0.children.isEmpty && $0.id != current && mayClose($0.id) }.map(\.id)
    }
}

extension Browser {
    /// This space's tabs as the journey draws them: never a private one.
    var journey: [JourneyTree.Placed] {
        JourneyTree.layout(tabs.filter { !$0.shy && !$0.isBlank }.map(\.id), parents: JourneyLog.shared.parents)
    }

    /// Whether the journey may archive a tab: what would let it close itself
    /// (Browser.stays), and not half of a split pair.
    func journeyMayArchive(_ id: Tab.ID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }) else { return false }
        return stays(because: tab) == nil && split(for: tab) == nil
            && ["http", "https", "file"].contains((tab.address ?? tab.page?.url)?.scheme?.lowercased() ?? "")
    }

    /// Archives these tabs and closes them, each asked first whether it holds
    /// something typed, as when tabs close themselves. The rest stay, and
    /// that is said.
    func archiveFromJourney(_ ids: [Tab.ID]) {
        var left = ids.filter { journeyMayArchive($0) }
        var archived = 0
        let asked = ids.count
        func next() {
            guard let id = left.popLast() else {
                let kept = asked - archived
                announce("Archived \(archived) \(archived == 1 ? "tab" : "tabs")"
                    + (kept > 0 ? "; kept \(kept) in use, pinned, grouped or holding something typed" : ""))
                return
            }
            guard let tab = tabs.first(where: { $0.id == id }) else { return next() }
            tab.unsaved { [weak self, weak tab] typed in
                // Asked again: you may have gone to it meanwhile.
                if let self, let tab, !typed, journeyMayArchive(tab.id) {
                    archive(tab)
                    close(tab)
                    archived += 1
                }
                next()
            }
        }
        next()
    }

    /// The tabs of a branch that can go to another space: never a pin.
    private func journeyMovable(_ ids: [Tab.ID]) -> [Tab] {
        ids.compactMap { id in tabs.first { $0.id == id && $0.pin == nil && !$0.bench && !$0.everywhere } }
    }

    /// A branch into a space of its own, named for the tab it starts at,
    /// signed in where this one is: nothing reloads.
    func journeyToNewSpace(_ ids: [Tab.ID]) {
        let members = journeyMovable(ids)
        guard prefs.usesSpaces, let first = members.first else { return }
        let from = spaceID
        let site = first.pageAddress?.host() ?? ""
        let name = Artifact.line(site.isEmpty ? first.title : Address.withoutWWW(site), 30)
        // A new space comes on screen unless something else is to be done
        // with it; the move is from this one, so it is gone back to first.
        afterSpaceCreated = { [weak self] made in
            guard let self, self.spaceID == from else { return }
            self.move(members, toSpace: made.id)
        }
        addSpace(named: name.isEmpty ? "Branch" : name)
    }

    func journeyMove(_ ids: [Tab.ID], toSpace id: UUID) {
        let members = journeyMovable(ids)
        if !members.isEmpty { move(members, toSpace: id) }
    }
}

/// View › Tab Journey: the trees, over the page.
struct JourneyCard: View {
    @ObservedObject var browser: Browser

    static let column: CGFloat = 210, line: CGFloat = 46, node = CGSize(width: 180, height: 36)

    private var close: () -> Void { { browser.journeying = false } }

    var body: some View {
        let placed = browser.journey
        let ends = JourneyTree.deadEnds(placed, current: browser.activeID, mayClose: browser.journeyMayArchive)
        Plate("Tab Journey", width: 760, close: close) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Each tab sits to the right of the one it was opened from, as far as this run remembers. Click one to go to it; right-click for its branch.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView([.horizontal, .vertical]) {
                    graph(placed, ends: Set(ends))
                }
                .frame(height: 380)
                HStack(spacing: 12) {
                    Quick("Archive \(ends.count) Dead \(ends.count == 1 ? "End" : "Ends")") { browser.archiveFromJourney(ends) }
                        .disabled(ends.isEmpty)
                        .help("The tabs drawn dashed: ends of a branch with nothing keeping them open")
                    Quick("Archived Tabs…") { close(); browser.archiving = true }
                    Spacer(minLength: 0)
                    if !browser.prefs.usesSpaces {
                        Text("Turn on Spaces in Settings to move a branch into one.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
        }
    }

    private func graph(_ placed: [JourneyTree.Placed], ends: Set<UUID>) -> some View {
        let at = Dictionary(placed.map { ($0.id, CGPoint(x: CGFloat($0.depth) * Self.column, y: CGFloat($0.row) * Self.line)) },
                            uniquingKeysWith: { a, _ in a })
        let across = CGFloat((placed.map(\.depth).max() ?? 0) + 1) * Self.column
        let down = CGFloat((placed.map(\.row).max() ?? 0) + 1) * Self.line
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for each in placed {
                    guard let parent = each.parent, let from = at[parent], let to = at[each.id] else { continue }
                    let start = CGPoint(x: from.x + Self.node.width, y: from.y + Self.node.height / 2)
                    let end = CGPoint(x: to.x, y: to.y + Self.node.height / 2)
                    let middle = (start.x + end.x) / 2
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: end.y))
                    context.stroke(path, with: .color(Palette.muted.opacity(0.5)), lineWidth: 1)
                }
            }
            .frame(width: across, height: down)
            .accessibilityHidden(true)
            ForEach(placed, id: \.id) { each in
                if let tab = browser.tabs.first(where: { $0.id == each.id }), let point = at[each.id] {
                    JourneyNode(browser: browser, tab: tab, placed: placed, node: each, deadEnd: ends.contains(each.id))
                        .offset(x: point.x, y: point.y)
                }
            }
        }
        .frame(width: across, height: down, alignment: .topLeading)
    }
}

private struct JourneyNode: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    let placed: [JourneyTree.Placed]
    let node: JourneyTree.Placed
    let deadEnd: Bool

    private var branch: [UUID] { JourneyTree.branch(node.id, in: placed) }
    private var title: String {
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? tab.pageAddress?.host() ?? "Tab" : title
    }

    var body: some View {
        let current = browser.activeID == tab.id
        HStack(spacing: 4) {
            Button {
                browser.journeying = false
                browser.select(tab)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title).font(.system(size: 11.5, weight: current ? .semibold : .regular))
                        .foregroundStyle(Palette.ink).lineLimit(1)
                    Text(verbatim: tab.pageAddress?.host() ?? "").font(.system(size: 9.5))
                        .foregroundStyle(Palette.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // One click: this tab and all that came from it, to a space of
            // their own.
            if browser.prefs.usesSpaces, node.parent == nil, !node.children.isEmpty {
                Button { browser.journeyToNewSpace(branch) } label: {
                    Image(systemName: "square.stack.badge.plus").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Move this tree to a new Space")
                .accessibilityLabel("Move this tree to a new Space")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: JourneyCard.node.width, height: JourneyCard.node.height)
        .background(current ? Palette.wash : Palette.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(current ? Palette.accent : Palette.hairline,
                              style: StrokeStyle(lineWidth: 1, dash: deadEnd ? [4, 3] : []))
        )
        .help(deadEnd ? "\(title) (dead end)" : title)
        .contextMenu {
            Button("Archive This Branch") { browser.archiveFromJourney(branch) }
            if browser.prefs.usesSpaces {
                Button("Move Branch to New Space") { browser.journeyToNewSpace(branch) }
                ForEach(browser.spaces.filter { $0.id != browser.spaceID }) { space in
                    Button("Move Branch to “\(space.name)”") { browser.journeyMove(branch, toSpace: space.id) }
                }
            }
        }
    }
}
