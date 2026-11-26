import XCTest
@testable import Search

/// icons8 asks a desktop app that uses its pictures for a link to
/// icons8.com in its About section. So the credit goes where the pictures go:
/// in a build that has them, and not in one that draws the plain circle.
final class ArtCreditTests: XCTestCase {
    private func bundle(pictures: [String]) throws -> Bundle {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Art"), withIntermediateDirectories: true)
        for name in pictures {
            try Data([0]).write(to: folder.appendingPathComponent("Art/\(name)"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return try XCTUnwrap(Bundle(url: folder))
    }

    func testABuildWithPicturesOwesTheCredit() throws {
        XCTAssertTrue(Art.credited(in: try bundle(pictures: ["welcome.png"])))
    }

    func testABuildWithoutThemDoesnt() throws {
        XCTAssertFalse(Art.credited(in: try bundle(pictures: [])))
    }

    func testTheCreditIsALinkToIcons8() {
        XCTAssertEqual(Art.creditWords, "Illustrations by Icons8")
        XCTAssertEqual(Art.creditLink.absoluteString, "https://icons8.com")
    }
}
