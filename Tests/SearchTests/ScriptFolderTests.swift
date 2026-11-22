import XCTest
@testable import Search

/// `search-mcp`, `bench`, `bench-mcp` and `fresh.sh` find the app's socket and
/// files by its folder's name, which they cannot read from Brand.swift (the
/// first is bundled alone, into the app). Renaming the folder once left the
/// side panel's Claude unable to reach the browser, so this says when a script
/// and Brand.folderName part ways.
final class ScriptFolderTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTheScriptsLookInTheFolderTheAppKeeps() throws {
        for name in ["search-mcp", "bench", "bench-mcp", "fresh.sh"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains(Brand.folderName), "\(name) names the app's folder, \(Brand.folderName)")
            for old in ["Application Support/\(Brand.legacyFolderName)", "{SUPPORT}/\(Brand.legacyFolderName)", "\"/\(Brand.legacyFolderName) (\""] {
                XCTAssertFalse(text.contains(old), "\(name) still looks in the upstream's folder: \(old)")
            }
        }
    }
}
