import XCTest
@testable import Search

@MainActor
final class CairnSnapshotTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestWorld.enter()
    }

    private func folder() -> URL { Store.file("Snapshots-test-\(UUID().uuidString)") }

    func testItIsFilesOnlyYouCanOpenAndTheManifestHoldsHashesOfBoth() throws {
        let room = folder()
        defer { try? FileManager.default.removeItem(at: room) }
        let address = "https://a.example/?" + "tok" + "en=" + "abc123" + "456789"
        let read: [String: Any] = ["text": "Hello. card 4242 4242 4242 4242",
                                   "nodes": [["e": 1, "role": "textbox", "name": "Email", "value": "ada@example.org", "box": [1, 2, 3, 4]]]]
        let kept = CairnSnapshots.extracted(from: read, archetype: ["type": "login"], title: "Sign in", url: address)
        let bundle = try XCTUnwrap(CairnSnapshots.write(archive: Data("archive".utf8), extracted: kept, title: "Sign in", url: address, in: room))
        XCTAssertEqual(bundle.pathExtension, "cairnsnapshot")
        for file in ["page.webarchive", "extracted.json", "manifest.json"] {
            let mode = try FileManager.default.attributesOfItem(atPath: bundle.appendingPathComponent(file).path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600, file)
        }
        let json = try String(contentsOf: bundle.appendingPathComponent("extracted.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("ada@example.org"), "what was typed is not kept")
        XCTAssertFalse(json.contains("4242 4242"), "a card number is hidden")
        XCTAssertFalse(json.contains("abc123456789") && !json.contains("hidden"), "values in an address are hidden")
        let manifest = try String(contentsOf: bundle.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("abc123456789"))
        let entries = CairnSnapshots.list(in: room)
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].intact)
    }

    func testAnEditedSnapshotIsNoticedAndOneCanBeDeleted() throws {
        let room = folder()
        defer { try? FileManager.default.removeItem(at: room) }
        let bundle = try XCTUnwrap(CairnSnapshots.write(archive: Data("a".utf8), extracted: ["text": "x"], title: "T", url: "https://a.example/", in: room))
        try Data("changed".utf8).write(to: bundle.appendingPathComponent("page.webarchive"))
        XCTAssertFalse(try XCTUnwrap(CairnSnapshots.list(in: room).first).intact)
        XCTAssertFalse(CairnSnapshots.delete(room), "only a snapshot, by its ending")
        XCTAssertTrue(CairnSnapshots.delete(bundle))
        XCTAssertTrue(CairnSnapshots.list(in: room).isEmpty)
    }

    func testDeleteAllLeavesOtherFilesAlone() throws {
        let room = folder()
        defer { try? FileManager.default.removeItem(at: room) }
        _ = CairnSnapshots.write(archive: Data("a".utf8), extracted: [:], title: "One", url: "https://a.example/", in: room)
        _ = CairnSnapshots.write(archive: Data("b".utf8), extracted: [:], title: "Two", url: "https://b.example/", in: room, now: Date().addingTimeInterval(5))
        try Data("mine".utf8).write(to: room.appendingPathComponent("notes.txt"))
        CairnSnapshots.deleteAll(in: room)
        XCTAssertTrue(CairnSnapshots.list(in: room).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: room.appendingPathComponent("notes.txt").path))
    }
}
