import XCTest
@testable import Search

/// `bench`, `bench-mcp` and `fresh.sh` find the app's socket and
/// files by its folder's name, which they cannot read from Brand.swift so this
/// says when a script and Brand.folderName part ways (cairn-mcp's name for it
/// is held to Brand's in CairnProtocolTests).
final class ScriptFolderTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTheScriptsLookInTheFolderTheAppKeeps() throws {
        for name in ["bench", "bench-mcp", "fresh.sh"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains(Brand.folderName), "\(name) names the app's folder, \(Brand.folderName)")
            for old in ["Application Support/\(Brand.legacyFolderName)", "{SUPPORT}/\(Brand.legacyFolderName)", "\"/\(Brand.legacyFolderName) (\""] {
                XCTAssertFalse(text.contains(old), "\(name) still looks in the upstream's folder: \(old)")
            }
        }
    }
}
