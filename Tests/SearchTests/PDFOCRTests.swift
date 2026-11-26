import AppKit
import WebKit
import XCTest
@testable import Search

/// read_page with ocr on a PDF: the picture is the one an agent gets, with
/// passwords, cards and frames blacked out, read by Vision.
@MainActor
final class PDFOCRTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// A scan, as a PDF holds one: the words are a picture, not text.
    private func scanned(_ words: String) throws -> Data {
        let size = CGSize(width: 600, height: 400)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 800, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 800).fill()
        (words as NSString).draw(at: NSPoint(x: 80, y: 500), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 80), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(try XCTUnwrap(bitmap.cgImage), in: box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    func testAScannedPDFsWordsAreReadFromTheAgentsPicture() async throws {
        _ = NSApplication.shared
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        defer { window.close() }
        web.load(try scanned("QUARTERLY REVENUE"), mimeType: "application/pdf", characterEncodingName: "",
                 baseURL: try XCTUnwrap(URL(string: "https://example.com/scan.pdf")))
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if !web.isLoading, (try? await web.evaluateJavaScript("document.contentType")) as? String == "application/pdf" { break }
        }
        try await Task.sleep(for: .seconds(1))

        let value = try await web.evaluateJavaScript(PageScripts.secrets, in: nil, contentWorld: Web.world)
        let found = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(value as? String).utf8)) as? [String: Any])
        let boxes = found["boxes"] as? [[Double]] ?? []
        let shot: NSBitmapImageRep = try await withCheckedThrowingContinuation { done in
            PageHands.snapshot(web, width: nil) { done.resume(with: $0) }
        }
        let plain = try XCTUnwrap(shot.representation(using: .png, properties: [:]))
        XCTAssertTrue((ImageText.lines(in: plain) ?? []).joined(separator: " ").uppercased().contains("REVENUE"),
                      "the picture shows the page at all, or this test shows nothing")
        let across = found["width"] as? Double ?? Double(shot.pixelsWide)
        let png = try XCTUnwrap(AgentControl.blackedOut(shot, boxes: boxes, scale: Double(shot.pixelsWide) / max(across, 1)))
        let read = (ImageText.lines(in: png) ?? []).joined(separator: " ").uppercased()
        XCTAssertTrue(read.contains("REVENUE"), "boxes: \(boxes), read: \(read)")
    }

    /// Only that: a frame or a plugin in a web page is covered as before.
    func testAWebPagesEmbedsAreStillBlackedOut() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        web.loadHTMLString("<body><embed style='display:block;width:300px;height:200px' type='application/pdf'></body>",
                           baseURL: try XCTUnwrap(URL(string: "https://example.com/")))
        for _ in 0..<50 where (try? await web.evaluateJavaScript("!!document.querySelector('embed')")) as? Bool != true {
            try await Task.sleep(for: .milliseconds(100))
        }
        let value = try await web.evaluateJavaScript(PageScripts.secrets, in: nil, contentWorld: Web.world)
        let found = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(value as? String).utf8)) as? [String: Any])
        XCTAssertEqual((found["boxes"] as? [[Double]])?.count, 1)
    }
}
