import CairnProtocol
import XCTest
@testable import Search

/// What the browser and cairn-mcp share, and the server as a client meets it
/// with no browser there.
@MainActor
final class CairnProtocolTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    func testTheSharedNamesAreTheAppsOwn() {
        XCTAssertEqual(AgentWire.folderName, Brand.folderName)
        XCTAssertEqual(AgentControl.verbs, Set(AgentVerb.allCases.map(\.rawValue)))
    }

    func testTheSocketIsInTheWorldsOwnFolder() {
        let base = "/Users/a/Library/Application Support/"
        XCTAssertEqual(AgentWire.socket(world: nil, home: "/Users/a"), base + "Cairn/Agent/agent.sock")
        XCTAssertEqual(AgentWire.socket(world: "", home: "/Users/a"), base + "Cairn/Agent/agent.sock")
        XCTAssertEqual(AgentWire.socket(world: "1", home: "/Users/a"), base + "Cairn (test)/Agent/agent.sock")
        XCTAssertEqual(AgentWire.socket(world: "Gate-2/../x", home: "/Users/a"), base + "Cairn (gate-2x)/Agent/agent.sock")
    }

    func testOnlyAPrivateSocketOfThisUsersIsSpokenTo() throws {
        // A short path: a socket's can't be long.
        let room = "/tmp/cmcp-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: room, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: room) }
        let path = room + "/agent.sock"
        XCTAssertFalse(AgentWire.isThisUsers(socket: path), "nothing there")
        FileManager.default.createFile(atPath: path, contents: Data())
        XCTAssertFalse(AgentWire.isThisUsers(socket: path), "a file is not a socket")
        try FileManager.default.removeItem(atPath: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertTrue(AgentWire.isThisUsers(socket: path))
        chmod(room, 0o755)
        XCTAssertFalse(AgentWire.isThisUsers(socket: path), "a folder others can open")
    }

    func testEveryToolSendsAVerbAndDeclaresWhatItPasses() throws {
        let names = MCPTools.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names.count, 17)
        for tool in MCPTools.all {
            XCTAssertTrue(tool.passes.allSatisfy { tool.properties[$0] != nil || $0 == "selector" }, tool.name)
            XCTAssertTrue(tool.required.allSatisfy { tool.properties[$0] != nil }, tool.name)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(tool.described), tool.name)
        }
        // wait_for offers no selector, but passes one on for the browser to
        // refuse: dropped here, the wait would succeed without it.
        let wait = try XCTUnwrap(MCPTools.all.first { $0.name == "wait_for" })
        XCTAssertNil(wait.properties["selector"])
        XCTAssertTrue(wait.passes.contains("selector"))
    }

    private func answer(_ server: MCPServer, _ line: String) throws -> [String: Any] {
        let out = try XCTUnwrap(server.reply(to: line))
        XCTAssertFalse(out.contains("\n"), "one line each")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    func testTheServerSpeaksMCP() throws {
        let server = MCPServer(socket: "/tmp/cairn-no-such-\(UUID().uuidString.prefix(6)).sock", pass: "")
        let started = try answer(server, #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(started["id"] as? String, "a")
        XCTAssertEqual((started["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        XCTAssertNil(server.reply(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertEqual((try answer(server, "not json")["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertEqual((try answer(server, #"{"id":2,"method":"nope"}"#)["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertNotNil(try answer(server, #"{"id":3,"method":"ping"}"#)["result"])
        // No browser there: said as a tool's error, and disconnect is fine.
        let refused = try XCTUnwrap(try answer(server, #"{"id":4,"method":"tools/call","params":{"name":"list_tabs"}}"#)["result"] as? [String: Any])
        XCTAssertEqual(refused["isError"] as? Bool, true)
        XCTAssertTrue(String(describing: refused["content"] ?? "").contains("not_listening"))
        let left = try XCTUnwrap(try answer(server, #"{"id":5,"method":"tools/call","params":{"name":"disconnect"}}"#)["result"] as? [String: Any])
        XCTAssertNil(left["isError"])
    }
}
