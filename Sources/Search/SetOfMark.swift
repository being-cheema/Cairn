import AppKit

// Set-of-mark grounding for a screenshot: numbered badges drawn on the
// picture, at the corner of each control the last read_page gave a handle, so
// a model that looks at the picture can say "e12" and mean the control it
// sees. The badges are drawn on the image after it is taken (CoreGraphics),
// from boxes the page's own script measured; nothing is added to the page, so
// the page can neither see nor move them. A control whose box touches an
// area that is blacked out is left without a badge, and a secret field is
// never given one, so the picture shows no more than it did.

enum SetOfMark {
    struct Mark: Equatable {
        /// The control's number in the last read (the `eN` of its handle).
        let index: Int
        /// Left, top, width, height, in CSS pixels of the viewport.
        let box: [Double]
    }

    /// Badges to a picture, so a busy page stays readable.
    static let most = 80

    /// [[index, x, y, w, h], …] as the page's script gives them.
    static func parse(_ any: Any?) -> [Mark] {
        (any as? [Any] ?? []).compactMap { item in
            guard let row = item as? [Any], row.count == 5 else { return nil }
            let numbers = row.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard numbers.count == 5, numbers[3] > 0, numbers[4] > 0 else { return nil }
            return Mark(index: Int(numbers[0]), box: Array(numbers[1...]))
        }
    }

    private static func touches(_ a: [Double], _ b: [Double]) -> Bool {
        a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3]
    }

    /// The marks that may be drawn: none that touch a blacked-out box.
    static func visible(_ marks: [Mark], masks: [[Double]]) -> [Mark] {
        let clear = masks.filter { $0.count == 4 }
        return Array(marks.filter { mark in !clear.contains { touches(mark.box, $0) } }.prefix(most))
    }

    /// Draws the badges into the current graphics context of a picture
    /// `height` pixels tall. `scale` takes CSS pixels to pixels, `points`
    /// pixels to the context's units.
    static func draw(_ marks: [Mark], masks: [[Double]], height: Double, scale: Double, points: CGFloat) {
        let font = NSFont.boldSystemFont(ofSize: max(10, 11 * scale) * points)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        for mark in visible(marks, masks: masks) {
            let label = NSAttributedString(string: "[e\(mark.index)]", attributes: attributes)
            let size = label.size()
            let x = mark.box[0] * scale * points
            let top = mark.box[1] * scale
            let badge = NSRect(x: x, y: (height - top) * points - size.height - 2 * points,
                               width: size.width + 6 * points, height: size.height + 2 * points)
            // A badge that would land on a blacked-out box is left off.
            let pixels = [badge.minX / points, height - badge.maxY / points, badge.width / points, badge.height / points]
            if masks.contains(where: { $0.count == 4 && touches(pixels, $0.map { $0 * scale }) }) { continue }
            NSColor(calibratedRed: 1, green: 0.85, blue: 0.1, alpha: 1).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3 * points, yRadius: 3 * points).fill()
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: badge, xRadius: 3 * points, yRadius: 3 * points)
            outline.lineWidth = points
            outline.stroke()
            label.draw(at: NSPoint(x: badge.minX + 3 * points, y: badge.minY + points))
        }
    }

    /// Where each control is, as the last read numbered them (`key`, `snap`):
    /// only what is in view, never a secret field. Reads the page; changes
    /// nothing in it.
    static func script(key: String, snap: Int) -> String {
        PageScripts.call(#"""
        (function (key, snap) {
          var kept = globalThis[key];
          if (!kept || kept.snap !== snap) return JSON.stringify({ error: 'stale_element', message: 'The page has changed since that read_page' });
          var out = [];
          kept.els.forEach(function (el, i) {
            if (!el || !el.isConnected || secret(el) || !visible(el)) return;
            var r = el.getBoundingClientRect();
            if (r.width <= 0 || r.height <= 0 || r.bottom < 0 || r.right < 0 || r.top >= innerHeight || r.left >= innerWidth) return;
            out.push([i, r.left, r.top, r.width, r.height]);
          });
          return JSON.stringify({ marks: out });
        })
        """#, [key, snap])
    }
}
