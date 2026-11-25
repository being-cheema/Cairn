import CryptoKit
import XCTest
@testable import Search

/// The keychain side of passkeys. Items live in the test world's label, and
/// every test removes what it made.
final class PasskeyStoreTests: XCTestCase {
    private var made: [PasskeyRecord] = []

    override func setUpWithError() throws {
        try XCTSkipIf(Store.world == nil, "Only the test world may touch the keychain")
        // A probe: if the keychain can't be written here, skip rather than fail.
        let probe = record(rp: "probe.example", user: 0)
        guard PasskeyStore.save(probe, key: P256.Signing.PrivateKey()) else {
            throw XCTSkip("The keychain isn't writable in this runner")
        }
        PasskeyStore.remove(probe)
    }

    override func tearDown() {
        made.forEach { PasskeyStore.remove($0) }
        made = []
    }

    private func record(rp: String, user: UInt8, at seconds: TimeInterval = 1_700_000_000) -> PasskeyRecord {
        PasskeyRecord(rp: rp, credentialID: Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
                      userHandle: Data([user, 2, 3]), userName: "u\(user)", displayName: "User \(user)",
                      created: Date(timeIntervalSince1970: seconds), lastUsed: nil)
    }

    @discardableResult
    private func keep(_ r: PasskeyRecord, _ key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) -> Bool {
        made.append(r)
        return PasskeyStore.save(r, key: key)
    }

    func testSaveThenReadBack() throws {
        let r = record(rp: "a.example", user: 1)
        let key = P256.Signing.PrivateKey()
        XCTAssertTrue(keep(r, key))
        XCTAssertEqual(PasskeyStore.records(rp: "a.example", allowed: []), [r])
        let back = try XCTUnwrap(PasskeyStore.key(for: r))
        XCTAssertEqual(back.rawRepresentation, key.rawRepresentation)
    }

    func testBackupEligibilityIsKept() throws {
        var r = record(rp: "be.example", user: 1)
        XCTAssertTrue(keep(r))
        XCTAssertEqual(PasskeyStore.records(rp: "be.example", allowed: []).first?.backupEligible, false)
        r.backupEligible = true
        XCTAssertTrue(keep(r))
        XCTAssertEqual(PasskeyStore.records(rp: "be.example", allowed: []).first?.backupEligible, true)
    }

    func testAllowedNarrowsAndNewestComesFirst() {
        let old = record(rp: "b.example", user: 1, at: 1_000)
        let new = record(rp: "b.example", user: 2, at: 2_000)
        keep(old); keep(new)
        keep(record(rp: "other.example", user: 3))
        XCTAssertEqual(PasskeyStore.records(rp: "b.example", allowed: []), [new, old])
        XCTAssertEqual(PasskeyStore.records(rp: "b.example", allowed: [old.credentialID]), [old])
        XCTAssertTrue(PasskeyStore.records(rp: "b.example", allowed: [Data([9])]).isEmpty)
    }

    func testSameSiteAndUserReplaces() {
        let first = record(rp: "c.example", user: 1)
        let second = record(rp: "c.example", user: 1)
        keep(first); keep(second)
        XCTAssertEqual(PasskeyStore.records(rp: "c.example", allowed: []), [second])
        XCTAssertNil(PasskeyStore.key(for: first))
        // A different user on the same site is kept beside it.
        let other = record(rp: "c.example", user: 2)
        keep(other)
        XCTAssertEqual(Set(PasskeyStore.records(rp: "c.example", allowed: []).map(\.id)), [second.id, other.id])
    }

    func testTouchSetsLastUsedAndKeepsTheKey() throws {
        let r = record(rp: "d.example", user: 1)
        let key = P256.Signing.PrivateKey()
        keep(r, key)
        PasskeyStore.touch(r)
        let read = try XCTUnwrap(PasskeyStore.records(rp: "d.example", allowed: []).first)
        XCTAssertNotNil(read.lastUsed)
        XCTAssertEqual(try XCTUnwrap(PasskeyStore.key(for: r)).rawRepresentation, key.rawRepresentation)
    }

    func testRemove() {
        let r = record(rp: "e.example", user: 1)
        keep(r)
        XCTAssertTrue(PasskeyStore.remove(r))
        XCTAssertFalse(PasskeyStore.remove(r))
        XCTAssertTrue(PasskeyStore.records(rp: "e.example", allowed: []).isEmpty)
        XCTAssertNil(PasskeyStore.key(for: r))
    }
}
