import XCTest
@testable import Search

@MainActor
final class PasskeyCapabilitiesTests: XCTestCase {
    /// Cairn's own passkeys make no PRF output and can't be reached from a
    /// phone: a build using them told sites, through getClientCapabilities,
    /// that it could do both (seen on webauthn.io from a probe).
    func testOwnPasskeysClaimNeitherPRFNorAPhone() {
        let own = PasskeyRelay.capabilities(macs: false)
        XCTAssertTrue(own.contains("c['extension:prf'] = false;"))
        XCTAssertTrue(own.contains("hybridTransport: false,"))
        XCTAssertFalse(own.contains("hybridTransport: true"))

        let macs = PasskeyRelay.capabilities(macs: true)
        XCTAssertTrue(macs.contains("c['extension:prf'] = \(Passkeys.prfAvailable);"))
        XCTAssertTrue(macs.contains("hybridTransport: true,"))
    }

    /// This test build has no entitlement, so the page script it hands out
    /// is the one for Cairn's own passkeys.
    func testTheUnentitledPageScriptSaysSo() {
        XCTAssertTrue(SoftPasskeys.on)
        XCTAssertTrue(PasskeyRelay.page.contains("c['extension:prf'] = false;"))
        XCTAssertFalse(PasskeyRelay.keysOnly.contains("extension:prf"))
    }

    /// A test run rehearses unless switched to the real passkeys, and the
    /// switch takes Cairn's own, never the Mac's sheet.
    func testTheRealSwitchIsOnlyEverOnByHand() {
        let was = Passkeys.realInTests
        defer { Passkeys.realInTests = was }
        Passkeys.realInTests = false
        XCTAssertTrue(Passkeys.rehearsing)
        Passkeys.realInTests = true
        XCTAssertFalse(Passkeys.rehearsing)
        XCTAssertTrue(SoftPasskeys.on)
    }
}
