import Foundation

// Words in a page that read as orders to an AI, marked as such before an agent
// is given them.
//
// A heuristic, and no more: it knows a few shapes in English, and an order
// written any other way goes through unmarked. It takes nothing away and
// allows nothing: every gate, question and redaction is the same whether a
// line was marked or not. What keeps an agent from acting on a page's words
// is those, not this.

enum Quarantine {
    static let opening = "[QUARANTINED PAGE DATA — UNTRUSTED]"
    static let closing = "[END QUARANTINED PAGE DATA]"

    private static let shapes = [
        #"\b(ignore|disregard|forget|override)\b.{0,40}\b(previous|prior|above|earlier|all|your|system|these)\b.{0,40}\b(instructions?|prompts?|rules|guidelines)\b"#,
        // A role only when an order follows: "System: macOS 14" is a spec sheet.
        #"^\s*(system|assistant|developer)\s*:\s*(you|ignore|disregard|do not|don't|never|now|from now|new)\b"#,
        #"<\|?(im_start|im_end|system)\|?>"#,
        #"\b(you are|act as) (now )?(an? )?(ai|assistant|language model|llm|chatbot|agent)\b"#,
        #"\b(ai|assistant|model|llm|agent)s?\b.{0,30}\b(must|should) (now )?(tell|say|add|include|output|open|visit|navigate|go to|click|send|submit|type|reply|forward)\b"#,
        #"\b(attention|note to|instructions? for|message for|important)\b.{0,20}\b(ai|assistants?|agents?|llms?|language models?|claude|chatgpt)\b"#,
        #"\bdo not (tell|inform|mention (this )?to|alert) (the )?(user|human|person)\b"#,
        #"\bnew (system )?instructions\s*:"#,
    ]

    static func suspicious(_ text: String) -> Bool {
        let plain = text.precomposedStringWithCompatibilityMapping
        return shapes.contains { plain.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// A page can write the markers itself, to seem to close a fence early:
    /// its own are rewritten, so the only ones left are the browser's.
    static func unmarked(_ text: String) -> String {
        text.replacingOccurrences(of: #"QUARANTINED[\s_]+PAGE[\s_]+DATA"#, with: "quarantine-marker written by the page",
                                  options: [.regularExpression, .caseInsensitive])
    }

    /// The text with each run of suspicious lines between the markers.
    static func fence(_ text: String) -> String {
        let lines = unmarked(text).components(separatedBy: "\n")
        var marked = lines.map(suspicious)
        // An order broken over two lines.
        for index in lines.indices.dropLast() where !marked[index] && !marked[index + 1] {
            if suspicious(lines[index] + " " + lines[index + 1]) { marked[index] = true; marked[index + 1] = true }
        }
        var out: [String] = []
        for (index, line) in lines.enumerated() {
            if marked[index], index == 0 || !marked[index - 1] { out.append(opening) }
            out.append(line)
            if marked[index], index == lines.count - 1 || !marked[index + 1] { out.append(closing) }
        }
        return out.joined(separator: "\n")
    }

    /// A short string, such as a title or a control's name: marked on one line.
    static func label(_ text: String) -> String {
        let clean = unmarked(text)
        return suspicious(clean) ? "\(opening) \(clean) \(closing)" : clean
    }

    /// What a read of a page gives an agent, with the page's own words marked:
    /// its title, its text and what its controls are called and hold.
    static func read(_ answer: [String: Any]) -> [String: Any] {
        var out = answer
        if let title = out["title"] as? String { out["title"] = label(title) }
        if let text = out["text"] as? String { out["text"] = fence(text) }
        // A whole read's controls, and a diff read's added, changed and gone.
        for list in ["nodes", "+", "~", "-"] {
            guard let nodes = out[list] as? [[String: Any]] else { continue }
            out[list] = nodes.map { node in
                var node = node
                for key in ["name", "value"] {
                    if let said = node[key] as? String { node[key] = label(said) }
                }
                return node
            }
        }
        for list in ["text+", "text-"] {
            if let lines = out[list] as? [String] { out[list] = lines.map(label) }
        }
        // The diff's one line quotes the page's names.
        if let summary = out["summary"] as? String { out["summary"] = label(summary) }
        // The page's JSON-LD: nobody looking at the page sees it.
        if let structured = out["structured"] { out["structured"] = deep(structured) }
        // The typed summary of what kind of page it is: all the page's words.
        if let kind = out["archetype"] { out["archetype"] = deep(kind) }
        return out
    }

    private static func deep(_ value: Any) -> Any {
        if let said = value as? String { return label(said) }
        if let list = value as? [Any] { return list.map(deep) }
        if let object = value as? [String: Any] { return object.mapValues(deep) }
        return value
    }
}
