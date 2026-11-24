import Foundation

/// New passwords, from the system's secure random numbers.
///
/// Two kinds: letters, digits and a few symbols, with the look-alikes left out
/// (no l, I, O, 0 or 1), and a passphrase of plain words. Both are made on
/// this Mac and shown once; nothing here is stored or sent.
enum PasswordGenerator {
    enum Style: String, CaseIterable, Identifiable {
        case random = "Random"
        case phrase = "Passphrase"
        var id: String { rawValue }
    }

    struct Options: Equatable {
        var style = Style.random
        /// Random: 12 to 40 characters.
        var length = 20
        /// Passphrase: 4 to 8 words.
        var words = 6
        var symbols = true

        static let lengths = 12...40
        static let wordCounts = 4...8

        /// What was last chosen, kept in the settings.
        static var saved: Options {
            get {
                let store = Store.settings
                var options = Options()
                options.style = store.string(forKey: "passwords.gen.style").flatMap(Style.init) ?? .random
                if let length = store.object(forKey: "passwords.gen.length") as? Int, lengths.contains(length) { options.length = length }
                if let words = store.object(forKey: "passwords.gen.words") as? Int, wordCounts.contains(words) { options.words = words }
                options.symbols = store.object(forKey: "passwords.gen.symbols") as? Bool ?? true
                return options
            }
            set {
                let store = Store.settings
                store.set(newValue.style.rawValue, forKey: "passwords.gen.style")
                store.set(newValue.length, forKey: "passwords.gen.length")
                store.set(newValue.words, forKey: "passwords.gen.words")
                store.set(newValue.symbols, forKey: "passwords.gen.symbols")
            }
        }
    }

    private static let lower = Array("abcdefghijkmnopqrstuvwxyz")
    private static let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let digits = Array("23456789")
    private static let symbols = Array("!#$%&*+-=?@^_")

    static func make(_ options: Options = .init()) -> String {
        var generator = SystemRandomNumberGenerator()
        return make(options, using: &generator)
    }

    static func make<G: RandomNumberGenerator>(_ options: Options, using generator: inout G) -> String {
        switch options.style {
        case .random: return random(options, using: &generator)
        case .phrase: return phrase(options, using: &generator)
        }
    }

    /// At least one of each kind, the rest from all of them, then shuffled so
    /// the first four characters are no more predictable than the others.
    private static func random<G: RandomNumberGenerator>(_ options: Options, using generator: inout G) -> String {
        let length = min(max(options.length, Options.lengths.lowerBound), Options.lengths.upperBound)
        var groups = [lower, upper, digits]
        if options.symbols { groups.append(symbols) }
        let all = groups.flatMap { $0 }
        var picked = groups.compactMap { $0.randomElement(using: &generator) }
        while picked.count < length { if let next = all.randomElement(using: &generator) { picked.append(next) } }
        picked.shuffle(using: &generator)
        return String(picked)
    }

    /// Words joined by hyphens, one of them capitalised, and two digits at the
    /// end: easy to read out and to type, and the sites that insist on a
    /// capital and a digit are satisfied.
    private static func phrase<G: RandomNumberGenerator>(_ options: Options, using generator: inout G) -> String {
        let count = min(max(options.words, Options.wordCounts.lowerBound), Options.wordCounts.upperBound)
        var words = (0..<count).compactMap { _ in PasswordWords.list.randomElement(using: &generator) }
        if !words.isEmpty {
            let at = Int.random(in: 0..<words.count, using: &generator)
            words[at] = words[at].prefix(1).uppercased() + words[at].dropFirst()
        }
        let number = Int.random(in: 10...99, using: &generator)
        return words.joined(separator: "-") + "-" + String(number)
    }

    /// How hard it is to guess, in bits, for the strength bar: every choice
    /// the generator made, counted.
    static func bits(_ options: Options) -> Double {
        switch options.style {
        case .random:
            let size = lower.count + upper.count + digits.count + (options.symbols ? symbols.count : 0)
            return Double(options.length) * log2(Double(size))
        case .phrase:
            return Double(options.words) * log2(Double(PasswordWords.list.count)) + log2(Double(options.words)) + log2(90)
        }
    }

    /// Words for the bar: past 60 bits is strong against anything a thief
    /// could throw at a stolen hash, past 80 is more than enough.
    static func strength(_ bits: Double) -> String {
        bits >= 80 ? "Very strong" : bits >= 60 ? "Strong" : bits >= 45 ? "Fair" : "Weak"
    }
}
