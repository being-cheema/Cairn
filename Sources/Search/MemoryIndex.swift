import CoreSpotlight
import Foundation
import NaturalLanguage
import SQLite3

// Where reading memory is kept: one SQLite file in the Memory folder, with a
// full-text index (FTS5) and, where this Mac has a sentence model for it, a
// vector a page (NLEmbedding) so a search can find what means the same in
// other words. All on this Mac.
//
// Every read and write is on one queue, and so is the count that clearing
// moves on. Work begun before a clear carries the count it began with, and is
// dropped if that has moved: nothing read before you cleared can be written
// after it, in the file or in Spotlight.

/// Spotlight, as far as this needs it. The tests stand in their own.
protocol MemorySpotlight: Sendable {
    func add(address: String, title: String, summary: String, _ done: @escaping @Sendable () -> Void)
    func remove(_ addresses: [String])
    func removeAll()
}

/// A test run puts nothing in this Mac's Spotlight.
struct NoSpotlight: MemorySpotlight {
    func add(address: String, title: String, summary: String, _ done: @escaping @Sendable () -> Void) { done() }
    func remove(_ addresses: [String]) {}
    func removeAll() {}
}

struct SystemSpotlight: MemorySpotlight {
    private static var domain: String { Brand.service("memory") }
    /// Set until macOS says the items are gone, so that a removal that failed,
    /// or that quitting cut short, is asked for again at the next launch.
    private static let owedKey = "memory.spotlight.owed"

    func add(address: String, title: String, summary: String, _ done: @escaping @Sendable () -> Void) {
        let attributes = CSSearchableItemAttributeSet(contentType: .url)
        attributes.title = title
        attributes.contentDescription = summary
        attributes.url = URL(string: address)
        let item = CSSearchableItem(uniqueIdentifier: address, domainIdentifier: Self.domain, attributeSet: attributes)
        CSSearchableIndex.default().indexSearchableItems([item]) { _ in done() }
    }

    func remove(_ addresses: [String]) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: addresses) { _ in }
    }

    func removeAll() {
        Store.settings.set(true, forKey: Self.owedKey)
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { error in
            if error == nil { Store.settings.removeObject(forKey: Self.owedKey) }
        }
    }

    static var removalOwed: Bool { Store.settings.bool(forKey: owedKey) }
}

struct RememberedPage: Equatable, Sendable {
    let address: String
    let title: String
    let text: String
    let added: Date
}

final class MemoryIndex: @unchecked Sendable {
    /// The oldest go beyond this, so a search stays quick.
    static let most = 3_000

    private let queue = DispatchQueue(label: "search.reading-memory", qos: .utility)
    private let folder: URL
    private let spotlight: MemorySpotlight
    private let embed: @Sendable (String) -> [Double]?
    private let limit: Int
    // Only on the queue.
    private var database: OpaquePointer?
    private var count = 0
    private var inSpotlight = false

    init(folder: URL, spotlight: MemorySpotlight, limit: Int = MemoryIndex.most,
         embed: @escaping @Sendable (String) -> [Double]? = MemoryIndex.sentenceVector) {
        self.folder = folder
        self.spotlight = spotlight
        self.limit = limit
        self.embed = embed
    }

    deinit { if let database { sqlite3_close(database) } }

    private var file: URL { folder.appendingPathComponent("memory.sqlite") }

    /// Asked as work begins, and handed back with what it made.
    var epoch: Int { queue.sync { count } }

    /// Whatever is under way is dropped when it arrives.
    func cancel() { queue.sync { count += 1 } }

    // MARK: writing

    func keep(address: String, title: String, text: String, epoch: Int, at date: Date = Date()) {
        queue.async { [self] in
            guard epoch == count, open(create: true) else { return }
            let vector = embed(title + ". " + String(text.prefix(600)))
            delete(address)
            guard run("INSERT INTO pages(url, title, body, added, vector) VALUES(?, ?, ?, ?, ?)",
                      [.text(address), .text(title), .text(text), .number(date.timeIntervalSince1970),
                       vector.map { .blob($0.withUnsafeBufferPointer { Data(buffer: $0) }) } ?? .nothing]) else { return }
            let row = sqlite3_last_insert_rowid(database)
            run("INSERT INTO words(rowid, title, body) VALUES(?, ?, ?)", [.integer(row), .text(title), .text(text)])
            let old = rows("SELECT url FROM pages ORDER BY added DESC, id DESC LIMIT -1 OFFSET ?", [.integer(Int64(limit))]) { Self.string($0, 0) }
            for each in old { delete(each) }
            if !old.isEmpty, inSpotlight { spotlight.remove(old) }
            if inSpotlight { surface(address: address, title: title, text: text, epoch: epoch) }
        }
    }

    /// On the queue. Spotlight answers when it likes: if what was asked of
    /// it has been cleared or switched off meanwhile, it is taken out again.
    private func surface(address: String, title: String, text: String, epoch: Int) {
        spotlight.add(address: address, title: title, summary: String(text.prefix(300))) { [weak self] in
            self?.queue.async {
                guard let self, epoch != self.count || !self.inSpotlight else { return }
                self.spotlight.remove([address])
            }
        }
    }

    /// Shown in Spotlight or not. Off takes everything out; on puts in what
    /// is kept already.
    func setSpotlight(_ on: Bool) {
        queue.sync {
            guard on != inSpotlight else { return }
            inSpotlight = on
            if !on {
                spotlight.removeAll()
            } else if open(create: false) {
                for page in recent(limit) { surface(address: page.address, title: page.title, text: page.text, epoch: count) }
            }
        }
    }

    /// One page forgotten, as when you remove it from History.
    func remove(where matches: (String) -> Bool) {
        queue.sync {
            count += 1
            guard open(create: false) else { return }
            let gone = rows("SELECT url FROM pages", []) { Self.string($0, 0) }.filter(matches)
            guard !gone.isEmpty else { return }
            for each in gone { delete(each) }
            spotlight.remove(gone)
        }
    }

    /// Everything: the file, what is in Spotlight, and what is on its way.
    func clear() {
        queue.sync {
            count += 1
            if let database { sqlite3_close(database) }
            database = nil
            try? FileManager.default.removeItem(at: folder)
            spotlight.removeAll()
        }
    }

    /// Waits for the writes asked for so far.
    func drain() { queue.sync {} }

    // MARK: reading

    var pageCount: Int {
        queue.sync {
            guard open(create: false) else { return 0 }
            return rows("SELECT count(*) FROM pages", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        }
    }

    func page(at address: String) -> RememberedPage? {
        queue.sync {
            guard open(create: false) else { return nil }
            return rows("SELECT url, title, body, added FROM pages WHERE url = ?", [.text(address)], Self.pageRow).first
        }
    }

    /// The pages that best answer to `words`: those with the words, and those
    /// whose meaning is close, ranked together by their places in the two
    /// lists.
    func search(_ words: String, limit: Int) -> [RememberedPage] {
        queue.sync {
            guard let match = Self.match(words), open(create: false) else { return [] }
            var score: [Int64: Double] = [:]
            let found = rows("SELECT rowid FROM words WHERE words MATCH ? ORDER BY bm25(words, 4.0, 1.0) LIMIT 50", [.text(match)]) {
                sqlite3_column_int64($0, 0)
            }
            for (place, row) in found.enumerated() { score[row, default: 0] += 1 / Double(10 + place) }
            if let asked = embed(words) {
                let close = rows("SELECT id, vector FROM pages WHERE vector IS NOT NULL", []) { statement -> (Int64, Double) in
                    (sqlite3_column_int64(statement, 0), Self.closeness(asked, Self.vector(statement, 1)))
                }.filter { $0.1 > Self.closeEnough }.sorted { $0.1 > $1.1 }.prefix(20)
                for (place, each) in close.enumerated() { score[each.0, default: 0] += 1 / Double(10 + place) }
            }
            return score.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }.prefix(limit).compactMap { entry in
                rows("SELECT url, title, body, added FROM pages WHERE id = ?", [.integer(entry.key)], Self.pageRow).first
            }
        }
    }

    /// The words as FTS5 takes them: each quoted, so nothing typed is read as
    /// its query language, any of them enough. The little words of a question
    /// are left out when there are others.
    static func match(_ words: String) -> String? {
        let all = words.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let little: Set<String> = ["a", "an", "the", "of", "to", "in", "on", "and", "or", "is", "was", "it", "that",
                                   "this", "what", "which", "did", "i", "read", "about", "my", "me", "for", "with"]
        let telling = all.filter { !little.contains($0) }
        let used = (telling.isEmpty ? all : telling).prefix(24)
        return used.isEmpty ? nil : used.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }

    // MARK: vectors

    /// The least cosine that counts as close, for Apple's sentence vectors.
    static let closeEnough = 0.35

    private static let model = NLEmbedding.sentenceEmbedding(for: .english)
    private static let modelLock = NSLock()

    /// Apple's sentence model, English only; nil where there is none, and
    /// then a search goes by the words alone.
    @Sendable static func sentenceVector(_ text: String) -> [Double]? {
        modelLock.lock()
        defer { modelLock.unlock() }
        return model?.vector(for: text)
    }

    static func closeness(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0, first: Double = 0, second: Double = 0
        for index in a.indices {
            dot += a[index] * b[index]
            first += a[index] * a[index]
            second += b[index] * b[index]
        }
        return first > 0 && second > 0 ? Double(dot / (first.squareRoot() * second.squareRoot())) : 0
    }

    // MARK: SQLite, on the queue

    private enum Value { case text(String), blob(Data), number(Double), integer(Int64), nothing }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func open(create: Bool) -> Bool {
        if database != nil { return true }
        let files = FileManager.default
        if !create, !files.fileExists(atPath: file.path) { return false }
        try? files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        if !files.fileExists(atPath: file.path) {
            _ = files.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        var made: OpaquePointer?
        guard sqlite3_open(file.path, &made) == SQLITE_OK else {
            sqlite3_close(made)
            return false
        }
        database = made
        // What is deleted is overwritten, not left in the file's free pages.
        let ready = run("PRAGMA secure_delete = ON", [])
            && run("CREATE TABLE IF NOT EXISTS pages(id INTEGER PRIMARY KEY, url TEXT UNIQUE, title TEXT, body TEXT, added REAL, vector BLOB)", [])
            && run("CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5(title, body, tokenize = 'unicode61 remove_diacritics 2')", [])
        if !ready {
            sqlite3_close(database)
            database = nil
        }
        return ready
    }

    private func delete(_ address: String) {
        run("DELETE FROM words WHERE rowid IN (SELECT id FROM pages WHERE url = ?)", [.text(address)])
        run("DELETE FROM pages WHERE url = ?", [.text(address)])
    }

    private func prepare(_ sql: String, _ values: [Value]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (index, value) in values.enumerated() {
            let place = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, place, text, -1, Self.transient)
            case .blob(let data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, place, $0.baseAddress, Int32($0.count), Self.transient) }
            case .number(let number): sqlite3_bind_double(statement, place, number)
            case .integer(let number): sqlite3_bind_int64(statement, place, number)
            case .nothing: sqlite3_bind_null(statement, place)
            }
        }
        return statement
    }

    @discardableResult
    private func run(_ sql: String, _ values: [Value]) -> Bool {
        guard let statement = prepare(sql, values) else { return false }
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        return result == SQLITE_DONE
    }

    private func rows<T>(_ sql: String, _ values: [Value], _ read: (OpaquePointer) -> T) -> [T] {
        guard let statement = prepare(sql, values) else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { out.append(read(statement)) }
        return out
    }

    private func recent(_ most: Int) -> [RememberedPage] {
        rows("SELECT url, title, body, added FROM pages ORDER BY added DESC LIMIT ?", [.integer(Int64(most))], Self.pageRow)
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func pageRow(_ statement: OpaquePointer) -> RememberedPage {
        RememberedPage(address: string(statement, 0), title: string(statement, 1), text: string(statement, 2),
                       added: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)))
    }

    private static func vector(_ statement: OpaquePointer, _ column: Int32) -> [Double] {
        let length = Int(sqlite3_column_bytes(statement, column))
        guard let bytes = sqlite3_column_blob(statement, column), length % MemoryLayout<Double>.size == 0 else { return [] }
        var out = [Double](repeating: 0, count: length / MemoryLayout<Double>.size)
        _ = out.withUnsafeMutableBytes { memcpy($0.baseAddress, bytes, length) }
        return out
    }
}
