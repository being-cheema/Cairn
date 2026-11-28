import Foundation

// The `cairn` command line (Cairn.app/Contents/MacOS/cairn-cli, linked as `cairn`): a small client
// of the same socket and the same checks cairn-mcp uses. It is one more
// program asking to use Cairn, so the person is asked about it as for any
// other, and every verb it sends is held to what an agent's is.
//
//   cairn md <url>        the page as Markdown, read in a fresh tab that keeps
//                         nothing and has none of your sign-ins
//   cairn ask "<prompt>"  puts the prompt in the Claude panel's box and waits
//                         for you to press Send there; nothing is started
//                         from here
//   cairn audit <url>     layout and console checks of a local site the Dev
//                         Bridge is on for; "bridge_off" otherwise
//
// Page text is data: what md prints is the page's own words, with any that
// look like orders fenced, and stdout carries nothing else.

public enum CairnCLI {
    public enum Command: Equatable {
        case md(String), ask(String), audit(String), help
    }

    public static let usage = """
    usage: cairn md <url>         print a page as Markdown (a fresh private tab, none of your sign-ins)
           cairn ask "<prompt>"   put a question in Cairn's Claude panel; you press Send there
           cairn audit <url>      layout and console checks of a local site (Dev Bridge on for it)
    """

    public static func parse(_ arguments: [String]) -> Command? {
        guard let verb = arguments.first else { return .help }
        let rest = arguments.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        switch verb {
        case "md" where !rest.isEmpty && arguments.count == 2: return .md(rest)
        case "audit" where !rest.isEmpty && arguments.count == 2: return .audit(rest)
        case "ask" where !rest.isEmpty: return .ask(rest)
        case "help", "-h", "--help": return .help
        default: return nil
        }
    }

    /// An address on this Mac, the only kind `audit` takes.
    public static func isLocal(_ text: String) -> Bool {
        guard let host = URL(string: text)?.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
    }

    /// What a run needs of the world, so a test can stand in for it.
    public struct World {
        public var ask: ([String: Any], TimeInterval) throws -> [String: Any]
        public var out: (String) -> Void
        public var err: (String) -> Void
        public var pause: (TimeInterval) -> Void
        public init(ask: @escaping ([String: Any], TimeInterval) throws -> [String: Any], out: @escaping (String) -> Void,
                    err: @escaping (String) -> Void, pause: @escaping (TimeInterval) -> Void) {
            self.ask = ask; self.out = out; self.err = err; self.pause = pause
        }
    }

    private static func said(_ error: Error) -> String {
        guard let refusal = error as? MCPRefusal else { return error.localizedDescription }
        return refusal.hint.isEmpty ? "\(refusal.code): \(refusal.message)" : "\(refusal.code): \(refusal.message) \(refusal.hint)"
    }

    /// Exit status: 0 done, 1 refused or failed, 2 `bridge_off`, 3 audit found
    /// something, 4 the question was never sent.
    public static func run(_ command: Command, in world: World, askPatience: TimeInterval = 900) -> Int32 {
        switch command {
        case .help:
            world.out(usage)
            return 0
        case .md(let address): return md(address, world)
        case .audit(let address): return audit(address, world)
        case .ask(let prompt): return ask(prompt, world, patience: askPatience)
        }
    }

    private static func md(_ address: String, _ world: World) -> Int32 {
        do {
            let opened = try world.ask(["do": "open", "url": address, "timeout": 30.0], 120)
            guard let page = opened["page"] as? String else { world.err("open: no page came back"); return 1 }
            defer { _ = try? world.ask(["do": "close", "page": page], 20) }
            let got = try world.ask(["do": "markdown", "page": page], 60)
            world.out((got["markdown"] as? String ?? "").trimmingCharacters(in: .newlines))
            if let note = got["untrusted"] as? String { world.err(note) }
            return 0
        } catch {
            world.err(said(error))
            return 1
        }
    }

    private static func audit(_ address: String, _ world: World) -> Int32 {
        guard isLocal(address) else {
            world.out("bridge_off")
            world.err("audit is for a local address with the Dev Bridge turned on for it (Cairn › site card).")
            return 2
        }
        do {
            let opened: [String: Any]
            do {
                opened = try world.ask(["do": "open", "url": address, "timeout": 30.0], 120)
            } catch {
                // An address that isn't granted is refused as a private one.
                world.out("bridge_off")
                world.err(said(error))
                return 2
            }
            guard let page = opened["page"] as? String else { world.err("open: no page came back"); return 1 }
            defer { _ = try? world.ask(["do": "close", "page": page], 20) }
            let report = try world.ask(["do": "assert_layout", "page": page], 60)
            guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return 1 }
            world.out(String(decoding: data, as: UTF8.self))
            func count(_ key: String) -> Int { (report[key] as? [Any])?.count ?? 0 }
            let overflow = ((report["horizontalOverflow"] as? [String: Any])?["by"] as? Int) ?? 0
            let found = count("overlaps") + count("clipped") + count("consoleErrors") + count("networkErrors") + (overflow > 1 ? 1 : 0)
            return found == 0 ? 0 : 3
        } catch {
            world.err(said(error))
            return 1
        }
    }

    private static func ask(_ prompt: String, _ world: World, patience: TimeInterval) -> Int32 {
        do {
            _ = try world.ask(["do": "ask_panel", "prompt": prompt], 120)
            world.err("Waiting for you to press Send in Cairn's Claude panel. Nothing is asked until you do.")
            var offset = 0
            var waited: TimeInterval = 0
            while waited < patience {
                let got = try world.ask(["do": "ask_poll", "offset": offset], 60)
                switch got["state"] as? String ?? "" {
                case "waiting":
                    break
                case "withdrawn":
                    world.err("The question was changed or cleared in the panel: nothing was sent.")
                    return 4
                default:
                    if let text = got["text"] as? String, !text.isEmpty { world.out(text) }
                    offset = got["length"] as? Int ?? offset
                    if got["state"] as? String == "done" {
                        if let failed = got["failed"] as? String { world.err(failed); return 1 }
                        return 0
                    }
                }
                world.pause(0.5)
                waited += 0.5
            }
            world.err("Nothing was sent within \(Int(patience / 60)) minutes. The question is still in the panel's box.")
            return 4
        } catch {
            world.err(said(error))
            return 1
        }
    }

    /// The real thing: the program's `main`.
    public static func main(arguments: [String], environment: [String: String]) -> Int32 {
        guard let command = parse(arguments) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 64
        }
        if command == .help {
            print(usage)
            return 0
        }
        let world = arguments.firstIndex(of: "--world").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? environment["SEARCH_PROBE"]
        let link = BrowserLink(path: AgentWire.socket(world: world, home: environment["HOME"] ?? NSHomeDirectory()), pass: "")
        link.client = "cairn (command line)"
        let live = World(
            ask: { try link.ask($0, within: $1) },
            out: { print($0); fflush(stdout) },
            err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
            pause: { Thread.sleep(forTimeInterval: $0) })
        let status = run(command, in: live)
        link.drop()
        return status
    }
}
