import Foundation
import NaturalLanguage

// What a read puts first when the agent says what it is looking for
// (read_page's focus_query), by words and, where the Mac has one, by Apple's
// on-device sentence embedding (NaturalLanguage). Nothing leaves the Mac, and
// nothing is added, removed or rewritten: a read's controls and its lines of
// text are only put in another order before the cut, so what the agent
// asked for is in the first part of what it is given. Every redaction and
// quarantine mark is the read's own and goes with the item it belongs to.
//
// Where there is no embedding (a language the Mac lacks, or none installed)
// it is the words of the question alone, and the answer says which it was.

struct FocusRank {
    enum Method: String { case embedding, terms }

    let query: String
    let method: Method
    private let terms: [String]
    private let queryVector: [Double]?
    private let vector: (String) -> [Double]?

    /// The words asked, or nil for none.
    init?(asked: String?, vector: ((String) -> [Double]?)? = nil) {
        let said = String((asked ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard !said.isEmpty else { return nil }
        self.init(query: said, vector: vector ?? Self.systemVector)
    }

    init(query: String, vector: @escaping (String) -> [Double]?) {
        self.query = query
        self.vector = vector
        terms = Self.words(query)
        queryVector = vector(query)
        method = queryVector == nil ? .terms : .embedding
    }

    /// The Mac's own English sentence embedding, or nil when there is none.
    static let systemVector: (String) -> [Double]? = {
        guard let model = NLEmbedding.sentenceEmbedding(for: .english) else { return { _ in nil } }
        return { model.vector(for: String($0.prefix(300))) }
    }()

    static func words(_ text: String) -> [String] {
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        // A short word like "a" or "of" decides nothing.
        return tokens.filter { $0.count > 2 || tokens.count == 1 || $0.allSatisfy(\.isNumber) }
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, x = 0.0, y = 0.0
        for index in a.indices { dot += a[index] * b[index]; x += a[index] * a[index]; y += b[index] * b[index] }
        return x > 0 && y > 0 ? dot / (x.squareRoot() * y.squareRoot()) : 0
    }

    /// How many of the question's words are in `text`, as a share, plus what
    /// the embedding says when there is one and the budget allows.
    func score(_ text: String, embed: Bool) -> Double {
        let lower = text.lowercased()
        let have = Set(Self.words(lower))
        let shared = terms.isEmpty ? 0 : Double(terms.filter { have.contains($0) || ($0.count >= 4 && lower.contains($0)) }.count) / Double(terms.count)
        guard embed, let queryVector, let there = vector(text) else { return shared }
        return shared + max(0, Self.cosine(queryVector, there)) * 0.5
    }

    /// The most things scored by the embedding; the rest by words alone.
    static let embedded = 400

    /// `items` with the likeliest first. Equal scores keep the page's order,
    /// and so does everything that matched nothing.
    func order<T>(_ items: [T], text: (T) -> String) -> [T] {
        let scored = items.enumerated().map { index, item in
            (index: index, item: item, score: score(text(item), embed: index < Self.embedded))
        }
        // Little scores are noise from the embedding: only a real match moves.
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.index < b.index
        }.map(\.item)
    }
}
