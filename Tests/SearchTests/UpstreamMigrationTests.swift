import XCTest
@testable import Search

/// What a person who used Search before this fork keeps: their folder is
/// copied, never moved, and their saved passwords are offered for copying,
/// never taken. The keychain here is the test world's own ("Search (test)"
/// and "Cairn (test)"), with made-up hosts and secrets, all removed after.
final class UpstreamMigrationTests: XCTestCase {
    private let host = "migration-test.example.invalid"
    private let user = "someone"
    private let secret = "not-a-real-password"
    // The labels as Vault builds them: a unit test runs outside the build
    // folder's test world, so these are the real ones, with a made-up host.
    private var legacyLabel: String { Store.world.map { "\(Brand.legacyKeychainLabel) (\($0))" } ?? Brand.legacyKeychainLabel }
    private var ownLabel: String { Store.world.map { "\(Brand.keychainLabel) (\($0))" } ?? Brand.keychainLabel }

    override func setUp() {
        super.setUp()
        removeAll()
    }

    override func tearDown() {
        removeAll()
        super.tearDown()
    }

    private func removeAll() {
        for label in [legacyLabel, ownLabel] {
            SecItemDelete([
                kSecClass as String: kSecClassInternetPassword,
                kSecAttrServer as String: host,
                kSecAttrLabel as String: label,
            ] as CFDictionary)
        }
    }

    /// An item as the upstream's build wrote it, under its label.
    private func keepAsUpstream() throws {
        let status = SecItemAdd([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrLabel as String: legacyLabel,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeHTMLForm,
            kSecValueData as String: Data(secret.utf8),
        ] as CFDictionary, nil)
        try XCTSkipIf(status != errSecSuccess, "the keychain isn't available to this run (\(status))")
    }

    func testWhatTheUpstreamKeptIsListedWithoutBeingTaken() throws {
        try keepAsUpstream()
        XCTAssertEqual(Vault.legacy().filter { $0.host == host }.map(\.user), [user])
        // Not ours until copied: the list under a sign-in box doesn't have it.
        XCTAssertTrue(Vault.kept(for: host).isEmpty)
    }

    func testCopyingKeepsTheOriginalAndMakesItOurs() throws {
        try keepAsUpstream()
        let items = Vault.legacy().filter { $0.host == host }
        let result = Vault.copyLegacy(items)
        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.skipped, 0)
        let ours = Vault.kept(for: host)
        XCTAssertEqual(ours.map(\.user), [user])
        XCTAssertEqual(ours.first.flatMap(Vault.secret(of:)), secret)
        // Already here, so no longer offered; and the upstream's is still
        // there for the app it belongs to.
        XCTAssertTrue(Vault.legacy().filter { $0.host == host }.isEmpty)
        var out: CFTypeRef?
        let still = SecItemCopyMatching([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrLabel as String: legacyLabel,
            kSecReturnAttributes as String: true,
        ] as CFDictionary, &out)
        XCTAssertEqual(still, errSecSuccess)
    }

    func testSavingAnAccountTheUpstreamAlsoKeepsDoesNotCollideWithIt() throws {
        try keepAsUpstream()
        // Same server and account, different app: both must exist.
        XCTAssertTrue(Vault.save(host: host, user: user, password: "ours"))
        XCTAssertEqual(Vault.kept(for: host).compactMap(Vault.secret(of:)), ["ours"])
        XCTAssertEqual(Vault.legacy().filter { $0.host == host }.count, 0, "ours now, so not offered")
        var out: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrLabel as String: legacyLabel,
            kSecReturnAttributes as String: true,
        ] as CFDictionary, &out), errSecSuccess, "the upstream's item is untouched")
    }

    func testAnAccountWeAlreadyHaveIsNotOfferedAgainOrOverwritten() throws {
        try keepAsUpstream()
        XCTAssertTrue(Vault.save(host: host, user: user, password: "newer-one"))
        XCTAssertTrue(Vault.legacy().filter { $0.host == host }.isEmpty)
        let ours = try XCTUnwrap(Vault.kept(for: host).first)
        XCTAssertEqual(Vault.secret(of: ours), "newer-one")
    }

    func testTheFolderIsCopiedNotMoved() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let upstream = root.appendingPathComponent("Search", isDirectory: true)
        let home = root.appendingPathComponent("Cairn", isDirectory: true)
        try files.createDirectory(at: upstream, withIntermediateDirectories: true)
        try Data("pins".utf8).write(to: upstream.appendingPathComponent("pins.json"))

        XCTAssertTrue(Store.copyUpstream(from: upstream, to: home))
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("pins.json"), encoding: .utf8), "pins")
        XCTAssertTrue(files.fileExists(atPath: upstream.appendingPathComponent("pins.json").path), "the upstream's copy stays")
        XCTAssertFalse(files.fileExists(atPath: root.appendingPathComponent("Cairn.copying").path))

        // Once it has a folder of its own, nothing is copied over it.
        try Data("mine".utf8).write(to: home.appendingPathComponent("pins.json"))
        XCTAssertFalse(Store.copyUpstream(from: upstream, to: home))
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("pins.json"), encoding: .utf8), "mine")
    }

    func testNothingToCopyWhenThereIsNoUpstreamFolder() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        XCTAssertFalse(Store.copyUpstream(from: missing, to: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }
}
