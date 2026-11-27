import CryptoKit
import Foundation

// A run that goes round in circles is stopped by the browser, not by the
// model's good sense: hard limits, in Swift, counted from what the browser
// saw (receipts and reads). Tripped, every action of the run is refused with
// LOOP_SUSPECTED and the trace that repeated, and the side panel says so.
//
// The limits can only stop things. A limit never starts, allows or approves
// anything, and the person's settings only move them within a range that
// keeps a limit in force.

struct LoopLimits: Equatable {
    var actions = 150
    var stalled = 5
    var identical = 3
    var minutes = 30

    static let ranges: [String: ClosedRange<Int>] = [
        "actions": 10...1000, "stalled": 2...50, "identical": 2...20, "minutes": 1...240,
    ]
    static let keys = ["actions": "agent.loop.actions", "stalled": "agent.loop.stalled",
                       "identical": "agent.loop.identical", "minutes": "agent.loop.minutes"]

    private static func clamp(_ name: String, _ value: Int) -> Int {
        let range = ranges[name] ?? 1...1000
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func load(_ defaults: UserDefaults = Store.settings) -> LoopLimits {
        var out = LoopLimits()
        func read(_ name: String, _ fallback: Int) -> Int {
            guard let key = keys[name], let value = defaults.object(forKey: key) as? Int else { return fallback }
            return clamp(name, value)
        }
        out.actions = read("actions", out.actions)
        out.stalled = read("stalled", out.stalled)
        out.identical = read("identical", out.identical)
        out.minutes = read("minutes", out.minutes)
        return out
    }

    func save(_ defaults: UserDefaults = Store.settings) {
        let all = ["actions": actions, "stalled": stalled, "identical": identical, "minutes": minutes]
        for (name, value) in all { if let key = Self.keys[name] { defaults.set(Self.clamp(name, value), forKey: key) } }
    }
}

struct LoopTrip: Equatable {
    enum Why: String { case actions, stalled, identical, time }
    let why: Why
    /// The last steps, in the browser's words: verb and what it came to,
    /// never the page's words.
    let trace: [String]

    var message: String {
        switch why {
        case .actions: "This run has used its whole allowance of actions"
        case .stalled: "The same control, or the same page, again and again with nothing changing"
        case .identical: "The same action with the same result, again and again"
        case .time: "This run has used its time"
        }
    }

    var said: [String: Any] {
        var out = AgentRefusal(code: "LOOP_SUSPECTED", message: message, hint: ActionFailure.loopSuspected.hint).said
        var error = out["error"] as? [String: Any] ?? [:]
        error["failure"] = ActionFailure.loopSuspected.rawValue
        error["trace"] = trace
        error["limit"] = why.rawValue
        out["error"] = error
        return out
    }
}

struct LoopBreaker {
    var limits: LoopLimits
    private let began: TimeInterval
    private(set) var actions = 0
    private var signatures: [String] = []
    private var stall: (key: String, count: Int) = ("", 0)
    private var rereads: (fingerprint: String, count: Int) = ("", 0)
    private var steps: [String] = []
    private(set) var tripped: LoopTrip?

    init(limits: LoopLimits = .load(), at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.limits = limits
        began = now
    }

    private mutating func note(_ step: String) {
        steps.append(step)
        if steps.count > 8 { steps.removeFirst() }
    }

    private mutating func trip(_ why: LoopTrip.Why) -> LoopTrip {
        let made = LoopTrip(why: why, trace: steps)
        tripped = made
        return made
    }

    /// Asked before every action of the run. Once tripped, always the same answer.
    mutating func admit(_ verb: String, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> LoopTrip? {
        if let tripped { return tripped }
        if now - began > Double(limits.minutes) * 60 { return trip(.time) }
        actions += 1
        if actions > limits.actions { note("\(verb) (action \(actions))"); return trip(.actions) }
        return nil
    }

    /// What an action came to: its signature (the dedupe key and where it
    /// left the page), the control it was on, and whether the page differs.
    mutating func took(_ verb: String, key: String, eid: String, before: String, after: String) -> LoopTrip? {
        rereads = ("", 0)
        note("\(verb) on \(eid.isEmpty ? "the page" : eid): " + (before == after ? "nothing changed" : "the page changed"))
        signatures.append(key + after)
        if signatures.count > limits.identical { signatures.removeFirst() }
        if signatures.count == limits.identical, Set(signatures).count == 1 { return trip(.identical) }
        let stalledKey = eid + before
        if before == after {
            stall = stall.key == stalledKey ? (stalledKey, stall.count + 1) : (stalledKey, 1)
        } else {
            stall = ("", 0)
        }
        if stall.count >= limits.stalled { return trip(.stalled) }
        return nil
    }

    /// A read of a page: the same page read again with no action between.
    mutating func read(fingerprint: String) -> LoopTrip? {
        note("read the page")
        rereads = rereads.fingerprint == fingerprint ? (fingerprint, rereads.count + 1) : (fingerprint, 1)
        return rereads.count > limits.stalled ? trip(.stalled) : nil
    }

    static func fingerprint(url: String, controls: [String], text: String) -> String {
        let all = ([url] + controls + [text]).joined(separator: "\u{1}")
        return SHA256.hash(data: Data(all.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
