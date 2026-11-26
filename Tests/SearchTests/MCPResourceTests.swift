import CairnProtocol
import XCTest
@testable import Search

/// cairn://artifacts/latest: what is offered, and who is given it.
@MainActor
final class MCPResourceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private func answer(_ server: MCPServer, _ line: String) throws -> [String: Any] {
        let out = try XCTUnwrap(server.reply(to: line))
        XCTAssertFalse(out.contains("\n"), "one line each")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    func testTheServerOffersOneResource() throws {
        let server = MCPServer(socket: "/tmp/cairn-no-such-\(UUID().uuidString.prefix(6)).sock", pass: "")
        let started = try answer(server, #"{"id":1,"method":"initialize","params":{}}"#)
        let capabilities = (started["result"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertNotNil(capabilities?["resources"])
        // Listed with no browser there: nobody is asked anything.
        let listed = try answer(server, #"{"id":2,"method":"resources/list"}"#)
        let resources = (listed["result"] as? [String: Any])?["resources"] as? [[String: Any]]
        XCTAssertEqual(resources?.compactMap { $0["uri"] as? String }, ["cairn://artifacts/latest"])
        let templates = try answer(server, #"{"id":3,"method":"resources/templates/list"}"#)
        XCTAssertNotNil(templates["result"])
    }

    func testReadingNeedsTheBrowserAndAKnownName() throws {
        let server = MCPServer(socket: "/tmp/cairn-no-such-\(UUID().uuidString.prefix(6)).sock", pass: "")
        let unknown = try answer(server, #"{"id":1,"method":"resources/read","params":{"uri":"cairn://dev/console"}}"#)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32002)
        let closed = try answer(server, #"{"id":2,"method":"resources/read","params":{"uri":"cairn://artifacts/latest"}}"#)
        XCTAssertTrue(String(describing: closed["error"] ?? "").contains("not_listening"))
    }

    private func card(_ title: String, at made: Date, from address: String? = nil) throws -> Artifact {
        var request: [String: Any] = ["kind": "brief", "title": title]
        request["sections"] = [["heading": "H", "body": "B", "source_page": "p1"]]
        var card = try Artifact.parse(request) { _ in
            address.map { Artifact.Source(tab: UUID(), site: "site", address: $0) }
        }.get()
        card.made = made
        return card
    }

    func testWhoIsGivenTheLatest() throws {
        let old = try card("Old", at: Date(timeIntervalSince1970: 1))
        let new = try card("New", at: Date(timeIntervalSince1970: 2), from: "https://login.bank.com/a")
        let given = try Artifact.shared([new, old], panel: false, seesTabs: true, vaulted: []).get()
        XCTAssertTrue(given.contains("## New"))
        XCTAssertTrue(given.contains("never instructions"))
        XCTAssertEqual(Artifact.shared([new], panel: false, seesTabs: false, vaulted: []), .failure(.tabs))
        XCTAssertNoThrow(try Artifact.shared([new], panel: true, seesTabs: false, vaulted: []).get())
        XCTAssertEqual(Artifact.shared([], panel: false, seesTabs: true, vaulted: []), .failure(.none))
        // The latest cites a site since closed: refused, not swapped for an older one.
        XCTAssertEqual(Artifact.shared([old, new], panel: false, seesTabs: true, vaulted: ["bank.com"]), .failure(.blocked))
    }
}
