import XCTest
import AppKit
import CairnProtocol
@testable import Search

/// Numbered badges drawn on a picture, never in the page, never over what is
/// blacked out.
@MainActor
final class SetOfMarkTests: XCTestCase {
    private func blank(_ w: Int, _ h: Int) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func isWhite(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return c.redComponent > 0.98 && c.greenComponent > 0.98 && c.blueComponent > 0.98
    }

    func testParsingKeepsOnlyWellFormedBoxes() {
        let marks = SetOfMark.parse([[3, 10, 20, 30, 40], [1, 1, 1], "x", [5, 0, 0, 0, 10]])
        XCTAssertEqual(marks, [SetOfMark.Mark(index: 3, box: [10, 20, 30, 40])])
    }

    func testACoveredControlGetsNoBadgeButOneWithNoAnswerKeepsIt() {
        let marks = SetOfMark.parse([[1, 0, 0, 10, 10, 1], [2, 20, 0, 10, 10, 0], [3, 40, 0, 10, 10]])
        XCTAssertEqual(marks.map(\.testable), [true, false, nil])
        XCTAssertEqual(SetOfMark.visible(marks, masks: []).map(\.index), [1, 3], "hit_testable false is not badged; absent is kept")
    }

    func testAMarkTouchingABlackedOutAreaIsDropped() {
        let marks = [SetOfMark.Mark(index: 1, box: [10, 10, 50, 20]), SetOfMark.Mark(index: 2, box: [190, 95, 30, 20])]
        let kept = SetOfMark.visible(marks, masks: [[200, 100, 80, 40]])
        XCTAssertEqual(kept.map(\.index), [1])
    }

    func testItIsBounded() {
        let marks = (0..<500).map { SetOfMark.Mark(index: $0, box: [Double($0 % 20) * 10, Double($0 / 20) * 10, 8, 8]) }
        XCTAssertLessThanOrEqual(SetOfMark.visible(marks, masks: []).count, SetOfMark.most)
    }

    func testBadgesAreDrawnButNeverOnTheBlackedOutArea() throws {
        let rep = try blank(400, 300)
        let marks = [SetOfMark.Mark(index: 7, box: [50, 50, 100, 30]), SetOfMark.Mark(index: 8, box: [190, 95, 30, 20])]
        let masks: [[Double]] = [[200, 100, 80, 40]]
        let data = try XCTUnwrap(AgentControl.blackedOut(rep, boxes: masks, scale: 1, marks: marks))
        XCTAssertFalse(data.isEmpty)
        XCTAssertFalse(isWhite(rep, 52, 52), "the badge is at the element's corner")
        XCTAssertTrue(isWhite(rep, 300, 250), "nothing else is touched")
        XCTAssertFalse(isWhite(rep, 250, 120), "the blacked-out area stays black")
        let c = try XCTUnwrap(rep.colorAt(x: 250, y: 120)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(c.redComponent + c.greenComponent + c.blueComponent, 0.05)
    }

    func testTheToolOffersMarksAndPassesThem() throws {
        let tool = try XCTUnwrap(MCPTools.all.first { $0.name == "screenshot" })
        XCTAssertNotNil(tool.properties["marks"])
        XCTAssertTrue(tool.description.contains("never"), "it says the page is not changed")
    }
}
