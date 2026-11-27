import Foundation

// A list drawn a few rows at a time (a virtualized or infinite one), gathered
// by scrolling it in overlapping steps and keeping each row once. Pure: the
// scrolling and the reading are AgentControl's and PageScripts', this is what
// is kept and when to stop.
//
// Read-only: the page is scrolled and put back, nothing is clicked. A row's
// words are the page's, so they are fenced as any page text is before an
// agent has them, and a field's value is never in a row (a row is read as
// the visible text it shows, which a field's value is not).

struct ListHarvest {
    struct Item: Equatable {
        var text: String
        var href: String?

        /// What makes a row the same one when it is drawn again: its address
        /// when it has one, and its words.
        var signature: String { (href ?? "") + "\u{1}" + text }
    }

    enum Stop: String, Equatable {
        case limit, text, end, time
    }

    static let defaultLimit = 100
    static let most = 500
    /// How long a gathering may take, however long the list.
    static let longest: TimeInterval = 25
    /// The most steps, whatever else.
    static let steps = 300

    static func limit(asked: Int?) -> Int { min(max(asked ?? defaultLimit, 1), most) }

    let limit: Int
    let stopText: String?
    private(set) var items: [Item] = []
    private(set) var stopped: Stop?
    private var seen = Set<String>()
    private var quietAtEnd = 0

    init(limit: Int, stopText: String? = nil) {
        self.limit = limit
        let said = stopText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.stopText = said?.isEmpty == false ? said : nil
    }

    /// The rows in view now; how many were new. Ends at the limit, or at the
    /// row that held the words asked for (that row is kept).
    @discardableResult
    mutating func add(_ rows: [Item]) -> Int {
        var added = 0
        for row in rows where stopped == nil {
            guard !row.text.isEmpty, seen.insert(row.signature).inserted else { continue }
            items.append(row)
            added += 1
            if let stopText, row.text.lowercased().contains(stopText) { stopped = .text }
            else if items.count >= limit { stopped = .limit }
        }
        if added > 0 { quietAtEnd = 0 }
        return added
    }

    /// After a step's rows were added: whether to go on. The end of the list
    /// twice over with nothing new is the end.
    mutating func step(atEnd: Bool, elapsed: TimeInterval) -> Stop? {
        if let stopped { return stopped }
        if atEnd { quietAtEnd += 1 }
        if quietAtEnd >= 2 { stopped = .end }
        else if elapsed > Self.longest { stopped = .time }
        return stopped
    }
}
