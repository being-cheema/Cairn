import Foundation

// The browser you have open, for a coding agent: an MCP server over stdio,
// run as cairn-mcp. One JSON-RPC message per line, and one connection to the
// browser, opened at the first tool call, not before.
//
// That first call puts a question in the window, Allow or Don't Allow, and
// waits for the answer (two minutes at a time; a call after that goes on
// waiting). The one run let in without it is the side panel's own: the
// browser starts it with a pass in the environment, shown at hello, and lets
// it in only if it is that very run. Anyone else showing a pass is simply
// asked. Everything that matters is decided in the browser, not here: what an
// agent may read or touch, which tabs, which addresses, what is kept back.
// This only passes requests along and says what came back.

public struct MCPRefusal: Error {
    public let code: String
    public let message: String
    public let hint: String

    init(_ code: String, _ message: String, _ hint: String = "") {
        self.code = code
        self.message = message
        self.hint = hint
    }

    var said: [String: Any] {
        var out: [String: Any] = ["code": code, "message": message]
        if !hint.isEmpty { out["hint"] = hint }
        return ["error": out]
    }
}

/// The connection to the browser, opened when first needed, and the question
/// it puts to the person.
final class BrowserLink {
    /// How long a call waits for the person to answer the question.
    static let asking: TimeInterval = 120

    private let path: String
    private let pass: String
    private var fd: Int32 = -1
    private var buffer = Data()
    private var counter = 0
    /// The hello whose answer hasn't come: the person hasn't answered yet.
    private var pendingHello: Int?
    var client = "A coding agent"

    init(path: String, pass: String) {
        self.path = path
        self.pass = pass
    }

    var connected: Bool { fd >= 0 }

    func drop() {
        if fd >= 0 { close(fd) }
        fd = -1
        pendingHello = nil
        buffer = Data()
    }

    private static func refusal(from line: Data) -> MCPRefusal {
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        let error = object?["error"] as? [String: Any] ?? [:]
        return MCPRefusal(error["code"] as? String ?? "stopped",
                          error["message"] as? String ?? "Cairn closed the connection",
                          error["hint"] as? String ?? "")
    }

    private func connect() throws {
        var info = stat()
        let there = lstat(path, &info) == 0
        if there, !AgentWire.isThisUsers(socket: path) {
            throw MCPRefusal("not_search", "The socket isn't one Cairn made for this user",
                             "Don't use it. Quitting Cairn and opening it again makes it afresh.")
        }
        guard there else {
            throw MCPRefusal("not_listening", "Cairn isn't open for coding agents",
                             "Is Cairn running? Ask the person to open it.")
        }
        let closed = MCPRefusal("not_listening", "Cairn isn't open for coding agents", "Is Cairn running?")
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw closed }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let made = socket(AF_UNIX, SOCK_STREAM, 0)
        guard made >= 0 else { throw closed }
        // A write to a browser that has gone fails; it must not end this.
        var on: Int32 = 1
        setsockopt(made, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(made, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(made)
            throw closed
        }
        // The browser turns a connection away at once (another agent, or just
        // told no): read that before saying anything, or the hello would meet
        // a closed socket and the reason would be lost.
        if Self.readable(made, within: 0.3) {
            let early = Self.read(made)
            close(made)
            throw Self.refusal(from: early.prefix { $0 != 0x0A })
        }
        fd = made
        buffer = Data()
        var hello: [String: Any] = ["do": AgentVerb.hello.rawValue, "client": client]
        // The side panel's own run only: shown to the browser, never to the
        // model.
        if !pass.isEmpty { hello["pass"] = pass }
        pendingHello = try send(hello)
    }

    private static func readable(_ fd: Int32, within seconds: TimeInterval) -> Bool {
        var watched = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let end = Date().addingTimeInterval(max(seconds, 0))
        while true {
            let left = Int32(max(end.timeIntervalSinceNow, 0) * 1000)
            let result = poll(&watched, 1, left)
            if result < 0, errno == EINTR { continue }
            return result > 0
        }
    }

    /// What is there now; empty when the other end has closed.
    private static func read(_ fd: Int32, flags: Int32 = 0) -> Data {
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        let count = recv(fd, &chunk, chunk.count, flags)
        return count > 0 ? Data(chunk[0..<count]) : Data()
    }

    @discardableResult
    private func send(_ request: [String: Any]) throws -> Int {
        counter += 1
        var request = request
        request["n"] = counter
        let gone = MCPRefusal("stopped", "The connection to Cairn is gone", "Call again to ask once more.")
        guard var line = try? JSONSerialization.data(withJSONObject: request) else {
            throw MCPRefusal("internal", "That request can't be written as JSON")
        }
        line.append(0x0A)
        var sent = 0
        while sent < line.count {
            let wrote = line.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.send(fd, base + sent, bytes.count - sent, 0)
            }
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else {
                drop()
                throw gone
            }
            sent += wrote
        }
        return counter
    }

    /// The answer to request `n`, or nil if it hasn't come in time.
    private func receive(_ n: Int, within patience: TimeInterval) throws -> [String: Any]? {
        let end = Date().addingTimeInterval(patience)
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let answer = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                // An answer with no number is the browser refusing the connection.
                if answer["n"] == nil || answer["n"] as? Int == n { return answer }
            }
            guard Self.readable(fd, within: end.timeIntervalSinceNow) else { return nil }
            let chunk = Self.read(fd)
            if chunk.isEmpty {
                drop()
                throw MCPRefusal("stopped", "Cairn ended the connection: the person pressed Stop, said no, or quit Cairn",
                                 "Don't ask again unless the person says so.")
            }
            buffer.append(chunk)
        }
    }

    private func waitForThePerson() throws {
        guard let n = pendingHello else { return }
        guard let answer = try receive(n, within: Self.asking) else {
            throw MCPRefusal("waiting_for_person", "Cairn is still asking the person whether you may use it",
                             "Tell the person to look at Cairn's window, then call again.")
        }
        pendingHello = nil
        if let error = answer["error"] as? [String: Any] {
            drop()
            throw MCPRefusal(error["code"] as? String ?? "not_allowed", error["message"] as? String ?? "",
                             error["hint"] as? String ?? "")
        }
    }

    /// Whether the browser let this connection go while nothing was asked (it
    /// says "idle", then closes): then the next request connects afresh,
    /// rather than taking it for Stop.
    private func letGo() -> Bool {
        guard fd >= 0, pendingHello == nil, Self.readable(fd, within: 0) else { return false }
        // Closed with nothing said is Stop, or the browser quitting: that is
        // for the next request to hear.
        buffer.append(Self.read(fd, flags: MSG_DONTWAIT))
        let text = String(decoding: buffer, as: UTF8.self)
        return text.contains("\"code\":\"idle\"") || text.contains("\"code\": \"idle\"")
    }

    func ask(_ request: [String: Any], within patience: TimeInterval = 60) throws -> [String: Any] {
        if letGo() { drop() }
        if fd < 0 { try connect() }
        try waitForThePerson()
        let n = try send(request)
        guard var answer = try receive(n, within: patience) else {
            throw MCPRefusal("no_answer", "\(request["do"] as? String ?? "That") got no answer within \(Int(patience)) s")
        }
        answer["n"] = nil
        if let error = answer["error"] {
            guard let error = error as? [String: Any] else { throw MCPRefusal("search", "\(error)") }
            throw MCPRefusal(error["code"] as? String ?? "search", error["message"] as? String ?? "",
                             error["hint"] as? String ?? "")
        }
        return answer
    }
}

public final class MCPServer {
    private static let versions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    /// How a client's own name is shown in the browser's question.
    private static let known = ["claude-code": "Claude Code", "codex": "Codex", "codex-mcp-client": "Codex"]

    private let link: BrowserLink

    public init(socket: String, pass: String) {
        link = BrowserLink(path: socket, pass: pass)
    }

    private static func text(_ object: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return String(decoding: data ?? Data("{}".utf8), as: UTF8.self)
    }

    private static func failed(_ object: [String: Any]) -> [String: Any] {
        ["content": [["type": "text", "text": text(object)]], "isError": true]
    }

    private static func seconds(_ value: Any?, or standard: Double) -> Double {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init) ?? standard
    }

    private func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        guard let tool = MCPTools.all.first(where: { $0.name == name }) else {
            return Self.failed(["error": ["code": "no_tool", "message": name]])
        }
        do {
            switch tool.verb {
            case .shot:
                var request: [String: Any] = ["do": tool.verb.rawValue, "page": arguments["page"] as? String ?? ""]
                let width = Self.seconds(arguments["width"], or: 0)
                if width > 0 { request["width"] = width }
                if arguments["marks"] as? Bool == true { request["marks"] = true }
                var answer = try link.ask(request)
                let png = answer.removeValue(forKey: "png") as? String ?? ""
                return ["content": [["type": "image", "data": png, "mimeType": "image/png"],
                                    ["type": "text", "text": Self.text(answer)]]]
            case .bye:
                if link.connected {
                    _ = try? link.ask(["do": tool.verb.rawValue], within: 5)
                    link.drop()
                }
                return ["content": [["type": "text", "text": Self.text(["disconnected": true])]]]
            default:
                var request: [String: Any] = ["do": tool.verb.rawValue]
                for key in tool.passes where arguments[key] != nil { request[key] = arguments[key] }
                // A held action may wait five minutes for the person's Approve,
                // and a sign-in fifteen for them to finish.
                let answer = try link.ask(request, within: Self.seconds(arguments["timeout"], or: 20) + 930)
                return ["content": [["type": "text", "text": Self.text(answer)]]]
            }
        } catch let refusal as MCPRefusal {
            return Self.failed(refusal.said)
        } catch {
            return Self.failed(["error": ["code": "internal", "message": error.localizedDescription]])
        }
    }

    /// One resource, as a JSON-RPC result or error.
    private func resource(_ uri: String) -> (key: String, value: Any) {
        func no(_ code: Int, _ message: String, _ data: [String: Any] = [:]) -> (key: String, value: Any) {
            var error: [String: Any] = ["code": code, "message": message]
            if !data.isEmpty { error["data"] = data }
            return ("error", error)
        }
        guard let verb = MCPResources.verb(for: uri) else { return no(-32002, "no resource \(uri)") }
        do {
            let answer = try link.ask(["do": verb.rawValue])
            let card = verb == .latestArtifact
            let text = card ? answer["markdown"] as? String ?? "" : Self.text(answer)
            return ("result", ["contents": [["uri": uri, "mimeType": card ? "text/markdown" : "application/json", "text": text]]])
        } catch let refusal as MCPRefusal {
            return no(-32002, refusal.message, refusal.said)
        } catch {
            return no(-32603, error.localizedDescription)
        }
    }

    /// The reply to one line from the client; nil for a notification.
    public func reply(to line: String) -> String? {
        func said(_ id: Any, _ key: String, _ value: Any) -> String {
            Self.text(["jsonrpc": "2.0", "id": id, key: value])
        }
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return said(NSNull(), "error", ["code": -32700, "message": "parse error"])
        }
        // A notification (initialized, cancelled) has no id and gets nothing.
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let info = params["clientInfo"] as? [String: Any]
            let name = (info?["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { link.client = Self.known[name.lowercased()] ?? name }
            let asked = params["protocolVersion"] as? String ?? ""
            return said(id, "result", [
                "protocolVersion": Self.versions.contains(asked) ? asked : Self.versions[Self.versions.count - 1],
                "capabilities": ["tools": ["listChanged": false],
                                 "resources": ["listChanged": false, "subscribe": false]],
                "serverInfo": ["name": "search", "version": "0.2.0"],
                "instructions": MCPTools.instructions,
            ] as [String: Any])
        case "ping":
            return said(id, "result", [String: Any]())
        // Listing says what there is without reaching the browser, so nothing
        // is asked of the person until something is read.
        case "resources/list":
            return said(id, "result", ["resources": MCPResources.all])
        case "resources/templates/list":
            return said(id, "result", ["resourceTemplates": [Any]()])
        case "resources/read":
            let uri = params["uri"] as? String ?? ""
            let read = resource(uri)
            return said(id, read.key, read.value)
        case "tools/list":
            return said(id, "result", ["tools": MCPTools.all.map(\.described)])
        case "tools/call":
            return said(id, "result", call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:]))
        default:
            return said(id, "error", ["code": -32601, "message": "no method \(method)"])
        }
    }

    /// Reads standard input until it closes, answering each line.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let out = reply(to: trimmed) else { continue }
            FileHandle.standardOutput.write(Data((out + "\n").utf8))
        }
        link.drop()
    }
}
