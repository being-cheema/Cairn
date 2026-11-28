import XCTest
@testable import Search

@MainActor
final class PasskeyInspectorTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// 32 bytes of RP hash, flags, 4-byte counter.
    private func authData(flags: UInt8, counter: UInt32 = 7) -> Data {
        var d = Data(repeating: 0xAB, count: 32)
        d.append(flags)
        d.append(contentsOf: [UInt8(counter >> 24 & 0xFF), UInt8(counter >> 16 & 0xFF), UInt8(counter >> 8 & 0xFF), UInt8(counter & 0xFF)])
        return d
    }

    func testFlagsAndCounterAreReadFromAuthenticatorData() throws {
        // UP, UV, BE, BS.
        let c = try XCTUnwrap(PasskeyInspector.ceremony(kind: "get", rp: "localhost", credentialID: Data([1, 2, 3]),
                                                        authenticatorData: authData(flags: 0x01 | 0x04 | 0x08 | 0x10)))
        XCTAssertTrue(c.userPresent && c.userVerified && c.backupEligible && c.backedUp)
        XCTAssertFalse(c.attested)
        XCTAssertEqual(c.counter, 7)
        XCTAssertEqual(c.credentialID, "AQID")
        let plain = try XCTUnwrap(PasskeyInspector.ceremony(kind: "create", rp: "localhost", credentialID: Data([9]), authenticatorData: authData(flags: 0x41)))
        XCTAssertFalse(plain.userVerified)
        XCTAssertTrue(plain.attested)
        XCTAssertNil(PasskeyInspector.ceremony(kind: "get", rp: "localhost", credentialID: Data(), authenticatorData: Data([1, 2])))
    }

    func testNothingIsKeptWithoutALiveGrantAndOnlyForThatOrigin() throws {
        let origin = try XCTUnwrap(DevOrigin(scheme: "http", host: "localhost", port: 3000))
        let c = try XCTUnwrap(PasskeyInspector.ceremony(kind: "get", rp: "localhost", credentialID: Data([1]), authenticatorData: authData(flags: 1)))
        let inspector = PasskeyInspector()
        inspector.note(c, for: origin, granted: false)
        XCTAssertNil(inspector.last(for: origin, granted: true))
        inspector.note(c, for: origin, granted: true)
        XCTAssertEqual(inspector.last(for: origin, granted: true), c)
        XCTAssertNil(inspector.last(for: origin, granted: false), "revoked: not shown")
        inspector.prune(granted: [])
        XCTAssertNil(inspector.last(for: origin, granted: true), "and forgotten")
    }

    func testItHoldsNothingBeyondPublicMetadata() {
        let names = Set(Mirror(reflecting: PasskeyCeremony(kind: "get", rp: "r", userPresent: true, userVerified: true, backupEligible: false,
                                                           backedUp: false, attested: false, counter: 1, credentialID: "x", at: Date())).children.compactMap(\.label))
        XCTAssertTrue(names.isDisjoint(with: ["privateKey", "key", "signature", "userHandle", "userName", "attestation"]))
    }
}
