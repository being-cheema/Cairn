import SwiftUI

// The rest of the drawn icon set (Glyphs.swift has the first). Same grid,
// same line; each name here is the system symbol's own, so a place that wore
// the symbol changes by nothing but the word `Ink`. A filled symbol is drawn
// as its outline, and a few near-twins share one drawing.

/// A pen on the 16-point grid: points are in grid units, not points.
private struct Pen {
    var path = Path()
    let x: CGFloat, y: CGFloat, s: CGFloat

    private func pt(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: x + a * s, y: y + b * s) }
    mutating func m(_ a: CGFloat, _ b: CGFloat) { path.move(to: pt(a, b)) }
    mutating func l(_ a: CGFloat, _ b: CGFloat) { path.addLine(to: pt(a, b)) }
    mutating func q(_ a: CGFloat, _ b: CGFloat, _ ca: CGFloat, _ cb: CGFloat) { path.addQuadCurve(to: pt(a, b), control: pt(ca, cb)) }
    mutating func c(_ a: CGFloat, _ b: CGFloat, _ c1a: CGFloat, _ c1b: CGFloat, _ c2a: CGFloat, _ c2b: CGFloat) {
        path.addCurve(to: pt(a, b), control1: pt(c1a, c1b), control2: pt(c2a, c2b))
    }
    mutating func line(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) { m(a, b); l(c, d) }
    mutating func rect(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, _ r: CGFloat = 1.6) {
        path.addRoundedRect(in: CGRect(x: x + a * s, y: y + b * s, width: (c - a) * s, height: (d - b) * s), cornerSize: CGSize(width: r * s, height: r * s))
    }
    mutating func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        path.addEllipse(in: CGRect(x: x + (cx - r) * s, y: y + (cy - r) * s, width: 2 * r * s, height: 2 * r * s))
    }
    /// An arc in the direction the angles grow, which on this grid is clockwise.
    mutating func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ from: Double, _ to: Double) {
        path.addArc(center: pt(cx, cy), radius: r * s, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
    }
    mutating func poly(_ points: [(CGFloat, CGFloat)], closed: Bool = false) {
        guard let first = points.first else { return }
        m(first.0, first.1)
        for p in points.dropFirst() { l(p.0, p.1) }
        if closed { path.closeSubpath() }
    }
}

private func ink(_ draw: @escaping (inout Pen) -> Void) -> InkGlyph {
    InkGlyph { x, y, s in
        var pen = Pen(x: x, y: y, s: s)
        draw(&pen)
        return pen.path
    }
}

extension InkGlyph {
    private static let window = ink { d in d.rect(2, 3, 14, 13, 2); d.line(2, 6.2, 14, 6.2) }
    private static let folderShape = ink { d in
        d.m(2, 11.5); d.l(2, 4.8); d.q(3.3, 3.5, 2, 3.5); d.l(6.4, 3.5); d.l(7.9, 5.4); d.l(12.7, 5.4)
        d.q(14, 6.7, 14, 5.4); d.l(14, 11.7); d.q(12.7, 13, 14, 13); d.l(3.5, 13); d.q(2, 11.5, 2, 13)
    }
    private static let lockBody = ink { d in d.rect(3.5, 7, 12.5 - 0, 13.5, 1.6) }
    private static let arrowCircle = ink { d in
        d.m(11.4, 3.2); d.arc(8, 8, 5.6, -45, 250); d.m(2.6, 3.6); d.l(2.6, 6.6)
    }
    private static let shield = ink { d in
        d.m(8, 2.2); d.l(13, 4); d.l(13, 8); d.q(8, 13.8, 13, 11.5); d.q(3, 8, 3, 11.5); d.l(3, 4); d.path.closeSubpath()
    }
    private static let moon = ink { d in
        d.m(12.5, 10.6); d.arc(8, 8, 5.6, 40, 300 - 0); d.q(12.5, 10.6, 9.4, 8)
    }
    private static let squareArrow = { (head: (CGFloat, CGFloat, CGFloat, CGFloat)) in
        ink { d in
            d.rect(2.5, 2.5, 13.5, 13.5, 2.2)
            d.line(head.0, head.1, head.2, head.3)
        }
    }

    static let more: [String: InkGlyph] = [
        "eye": ink { d in d.m(1.8, 8); d.c(14.2, 8, 5, 3, 11, 3); d.c(1.8, 8, 11, 13, 5, 13); d.circle(8, 8, 2.1) },
        "leaf": ink { d in d.m(3, 13); d.c(13, 3, 3, 5, 8, 3); d.c(3, 13, 13, 9, 8, 13); d.line(3, 13, 9, 7) },
        "link": ink { d in d.rect(1.8, 5.6, 8.4, 10.4, 2.4); d.rect(7.6, 5.6, 14.2, 10.4, 2.4); d.line(6.4, 8, 9.6, 8) },
        "link.badge.plus": ink { d in d.rect(1.8, 4, 8.4, 8.8, 2.4); d.rect(7.6, 4, 14.2, 8.8, 2.4); d.line(8, 12, 8, 14.6); d.line(6.7, 13.3, 9.3, 13.3) },
        "power": ink { d in d.line(8, 2.4, 8, 7.4); d.m(11.2, 4.8); d.arc(8, 8.6, 5, -50, 230) },
        "puzzlepiece.extension": ink { d in d.rect(3, 5.5, 13, 13.2, 1.6); d.circle(8, 4, 1.7) },
        "person.2": ink { d in d.circle(6, 5.4, 2.3); d.m(1.8, 13.4); d.c(10.2, 13.4, 2.4, 8.4, 9.6, 8.4); d.circle(11.4, 6, 1.8); d.m(11.6, 9.2); d.c(14.4, 12, 13.2, 9.4, 14.2, 10.6) },
        "person.badge.key": ink { d in d.circle(6.4, 5.4, 2.5); d.m(2, 13.4); d.c(10.8, 13.4, 2.6, 8.2, 10.2, 8.2); d.circle(12, 10, 1.2); d.line(13, 11, 14, 12.2) },
        "person.badge.plus": ink { d in d.circle(6.4, 5.4, 2.5); d.m(2, 13.4); d.c(10.8, 13.4, 2.6, 8.2, 10.2, 8.2); d.line(12.4, 9, 12.4, 12.6); d.line(10.6, 10.8, 14.2, 10.8) },
        "person.crop.rectangle": ink { d in d.rect(2, 3, 14, 13, 2); d.circle(8, 7, 1.8); d.m(4.8, 11.4); d.c(11.2, 11.4, 5.2, 8.6, 10.8, 8.6) },
        "person.crop.circle.badge.xmark": ink { d in d.circle(8, 8, 6); d.circle(8, 6.6, 1.8); d.m(4.8, 12); d.c(11.2, 12, 5.2, 8.8, 10.8, 8.8) },
        "arrow.clockwise": ink { d in d.m(11.6, 3.8); d.arc(8, 8, 5.2, -45, 250); d.poly([(12.4, 1.8), (11.6, 4), (9.4, 3.4)]) },
        "arrow.triangle.2.circlepath": ink { d in d.m(11.6, 3.8); d.arc(8, 8, 5.2, -45, 250); d.poly([(12.4, 1.8), (11.6, 4), (9.4, 3.4)]) },
        "questionmark": ink { d in d.m(5.6, 6.2); d.arc(8, 6.2, 2.4, 180, 420); d.l(8, 9.4); d.line(8, 12.4, 8, 12.45) },
        "paintpalette": ink { d in d.rect(1.8, 3.6, 14.2, 12.4, 5); d.circle(5.4, 8, 0.4); d.circle(8, 6, 0.4); d.circle(10.8, 7, 0.4) },
        "rectangle.stack": ink { d in d.rect(2.5, 6.4, 13.5, 13.5, 2); d.line(4.5, 4.2, 11.5, 4.2); d.line(6, 2.6, 10, 2.6) },
        "command": ink { d in
            d.rect(5.5, 5.5, 10.5 - 0, 10.5, 0)
            for (cx, cy) in [(4.0, 4.0), (12.0, 4.0), (4.0, 12.0), (12.0, 12.0)] { d.circle(CGFloat(cx), CGFloat(cy), 1.7) }
        },
        "macwindow": window,
        "macwindow.on.rectangle": ink { d in d.rect(2, 5, 12, 14, 2); d.line(2, 7.8, 12, 7.8); d.m(4.5, 3); d.l(14, 3); d.l(14, 11) },
        "arrow.uturn.backward": ink { d in
            d.poly([(5.2, 3.8), (2.6, 6.5), (5.2, 9.2)]); d.m(2.6, 6.5); d.l(10, 6.5); d.q(13.5, 9.5, 13.5, 6.5); d.q(10, 12.5, 13.5, 12.5); d.l(6.5, 12.5)
        },
        "arrow.uturn.backward.circle": ink { d in d.circle(8, 8, 6); d.poly([(6.5, 5.6), (4.8, 7.3), (6.5, 9)]); d.m(4.8, 7.3); d.l(9, 7.3); d.q(11, 8.6, 11, 7.3); d.q(9, 10, 11, 10); d.l(7, 10) },
        "rectangle.split.2x1": ink { d in d.rect(2, 3, 14, 13, 2); d.line(8, 3, 8, 13) },
        "xmark.circle.fill": ink { d in d.circle(8, 8, 6); d.line(5.8, 5.8, 10.2, 10.2); d.line(10.2, 5.8, 5.8, 10.2) },
        "xmark.circle": ink { d in d.circle(8, 8, 6); d.line(5.8, 5.8, 10.2, 10.2); d.line(10.2, 5.8, 5.8, 10.2) },
        "checkmark.circle": ink { d in d.circle(8, 8, 6); d.poly([(5.2, 8.2), (7.2, 10.2), (10.9, 5.9)]) },
        "minus.circle": ink { d in d.circle(8, 8, 6); d.line(5, 8, 11, 8) },
        "play.circle": ink { d in d.circle(8, 8, 6); d.poly([(6.6, 5.4), (10.8, 8), (6.6, 10.6)], closed: true) },
        "stop.circle": ink { d in d.circle(8, 8, 6); d.rect(5.7, 5.7, 10.3, 10.3, 0.8) },
        "record.circle": ink { d in d.circle(8, 8, 6); d.circle(8, 8, 2.4) },
        "arrow.down.circle": ink { d in d.circle(8, 8, 6); d.line(8, 4.8, 8, 11); d.poly([(5.6, 8.8), (8, 11.2), (10.4, 8.8)]) },
        "arrow.up.and.down.circle": ink { d in d.circle(8, 8, 6); d.line(8, 4.8, 8, 11.2); d.poly([(6.2, 6.4), (8, 4.6), (9.8, 6.4)]); d.poly([(6.2, 9.6), (8, 11.4), (9.8, 9.6)]) },
        "arrow.up.and.down": ink { d in d.line(8, 3, 8, 13); d.poly([(5.4, 5.6), (8, 3), (10.6, 5.6)]); d.poly([(5.4, 10.4), (8, 13), (10.6, 10.4)]) },
        "arrow.left.arrow.right": ink { d in d.line(3, 5.5, 13, 5.5); d.poly([(10.4, 3), (13, 5.5), (10.4, 8)]); d.line(13, 10.5, 3, 10.5); d.poly([(5.6, 8), (3, 10.5), (5.6, 13)]) },
        "arrow.down.to.line": ink { d in d.line(8, 2.5, 8, 10.5); d.poly([(4.8, 7.6), (8, 10.8), (11.2, 7.6)]); d.line(3.5, 13.5, 12.5, 13.5) },
        "arrow.right.to.line": ink { d in d.line(2.5, 8, 10.5, 8); d.poly([(7.6, 4.8), (10.8, 8), (7.6, 11.2)]); d.line(13.5, 3.5, 13.5, 12.5) },
        "arrow.right.to.line.compact": ink { d in d.line(2.5, 8, 10.5, 8); d.poly([(7.6, 4.8), (10.8, 8), (7.6, 11.2)]); d.line(13.5, 3.5, 13.5, 12.5) },
        "arrow.turn.down.right": ink { d in d.m(3, 3); d.l(3, 9); d.q(5, 11, 3, 11); d.l(12, 11); d.poly([(9.6, 8.4), (12.4, 11), (9.6, 13.6)]) },
        "arrow.up.forward.square": squareArrow((6.5, 9.5, 11.5, 4.5)),
        "arrow.down.forward.square": squareArrow((6.5, 6.5, 11.5, 11.5)),
        "arrow.right.square": ink { d in d.rect(2.5, 2.5, 13.5, 13.5, 2.2); d.line(5, 8, 11, 8); d.poly([(8.6, 5.6), (11, 8), (8.6, 10.4)]) },
        "arrow.up.left.and.arrow.down.right": ink { d in d.line(3, 3, 13, 13); d.poly([(3, 7), (3, 3), (7, 3)]); d.poly([(9, 13), (13, 13), (13, 9)]) },
        "arrow.down.right.and.arrow.up.left": ink { d in d.line(3, 3, 13, 13); d.poly([(7, 3), (7, 7), (3, 7)]); d.poly([(13, 9), (9, 9), (9, 13)]) },
        "arrow.down.left.and.arrow.up.right": ink { d in d.line(3, 13, 13, 3); d.poly([(3, 9), (3, 13), (7, 13)]); d.poly([(9, 3), (13, 3), (13, 7)]) },
        "chevron.left": ink { d in d.poly([(10, 3), (5, 8), (10, 13)]) },
        "chevron.right.square": ink { d in d.rect(2.5, 2.5, 13.5, 13.5, 2.2); d.poly([(7, 5.4), (9.8, 8), (7, 10.6)]) },
        "minus": ink { d in d.line(3, 8, 13, 8) },
        "folder.fill": folderShape,
        "questionmark.folder": folderShape,
        "lock": ink { d in d.rect(3.5, 7, 12.5, 13.5, 1.8); d.m(5.5, 7); d.l(5.5, 5.2); d.arc(8, 5.2, 2.5, 180, 360); d.l(10.5, 7) },
        "lock.open": ink { d in d.rect(3.5, 7, 12.5, 13.5, 1.8); d.m(5.5, 7); d.l(5.5, 5.2); d.arc(8, 5.2, 2.5, 180, 360); d.l(10.5, 3.6) },
        "lock.trianglebadge.exclamationmark": ink { d in d.rect(3.5, 7, 12.5, 13.5, 1.8); d.m(5.5, 7); d.l(5.5, 5.2); d.arc(8, 5.2, 2.5, 180, 360); d.l(10.5, 7); d.line(8, 9.4, 8, 11); d.line(8, 12, 8, 12.05) },
        "flask": ink { d in d.m(6, 2.5); d.l(6, 6.6); d.l(2.9, 12.2); d.q(3.8, 13.5, 2.9, 13.5); d.l(12.2, 13.5); d.q(13.1, 12.2, 13.1, 13.5); d.l(10, 6.6); d.l(10, 2.5); d.line(5, 2.5, 11, 2.5); d.line(4.6, 9.6, 11.4, 9.6) },
        "circle.lefthalf.filled": ink { d in d.circle(8, 8, 6); d.line(8, 2, 8, 14); d.line(5.4, 5, 5.4, 11) },
        "circle.righthalf.filled": ink { d in d.circle(8, 8, 6); d.line(8, 2, 8, 14); d.line(10.6, 5, 10.6, 11) },
        "moon": moon, "moon.zzz": moon, "moon.stars": moon,
        "sun.max": ink { d in
            d.circle(8, 8, 2.8)
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                d.line(8 + 4.8 * CGFloat(cos(a)), 8 + 4.8 * CGFloat(sin(a)), 8 + 6.4 * CGFloat(cos(a)), 8 + 6.4 * CGFloat(sin(a)))
            }
        },
        "sunrise": ink { d in d.arc(8, 11, 3.4, 180, 360); d.line(2, 11, 14, 11); d.line(8, 3.5, 8, 5.6); d.line(3.4, 6.4, 4.8, 7.8); d.line(12.6, 6.4, 11.2, 7.8) },
        "pin": ink { d in d.m(6, 2.8); d.l(10, 2.8); d.l(9.4, 7); d.l(11.6, 9); d.l(4.4, 9); d.l(6.6, 7); d.path.closeSubpath(); d.line(8, 9, 8, 13.6) },
        "pin.slash": ink { d in d.m(6, 2.8); d.l(10, 2.8); d.l(9.4, 7); d.l(11.6, 9); d.l(4.4, 9); d.l(6.6, 7); d.path.closeSubpath(); d.line(8, 9, 8, 13.6); d.line(2.5, 2.5, 13.5, 13.5) },
        "character.cursor.ibeam": ink { d in d.line(8, 3, 8, 13); d.line(5.8, 3, 10.2, 3); d.line(5.8, 13, 10.2, 13) },
        "shield": shield, "checkmark.shield": ink { d in
            d.m(8, 2.2); d.l(13, 4); d.l(13, 8); d.q(8, 13.8, 13, 11.5); d.q(3, 8, 3, 11.5); d.l(3, 4); d.path.closeSubpath()
            d.poly([(5.8, 8), (7.5, 9.7), (10.4, 6.4)])
        },
        "shield.lefthalf.filled": shield,
        "envelope": ink { d in d.rect(2, 3.5, 14, 12.5, 1.8); d.poly([(2.4, 4.6), (8, 9), (13.6, 4.6)]) },
        "envelope.badge": ink { d in d.rect(2, 4.5, 12, 13, 1.8); d.poly([(2.4, 5.6), (7, 9.4), (11.6, 5.6)]); d.circle(13, 3.5, 1.2) },
        "paintbrush": ink { d in d.line(12.5, 2.5, 7.5, 8.5); d.m(7.5, 8.5); d.l(5.4, 8.8); d.q(4.2, 12.6, 4.4, 10.8); d.q(8.6, 11.6, 7.2, 12.6); d.l(8, 10) },
        "rectangle.on.rectangle": ink { d in d.rect(2.5, 5, 10.5, 13.5, 1.8); d.m(5.5, 3); d.l(13.5, 3); d.l(13.5, 10.5) },
        "rectangle.on.rectangle.slash": ink { d in d.rect(2.5, 5, 10.5, 13.5, 1.8); d.m(5.5, 3); d.l(13.5, 3); d.l(13.5, 10.5); d.line(2, 14, 14, 2) },
        "rectangle.3.group": ink { d in d.rect(2, 3, 7, 13, 1.4); d.rect(9.5, 3, 14, 7.5, 1.4); d.rect(9.5, 9.5, 14, 13, 1.4) },
        "square.stack.3d.up": ink { d in d.poly([(8, 2.6), (13.6, 5.4), (8, 8.2), (2.4, 5.4)], closed: true); d.poly([(2.4, 8), (8, 10.8), (13.6, 8)]); d.poly([(2.4, 10.6), (8, 13.4), (13.6, 10.6)]) },
        "square.and.arrow.down": ink { d in d.m(5, 7); d.l(3.5, 7); d.l(3.5, 13.5); d.l(12.5, 13.5); d.l(12.5, 7); d.l(11, 7); d.line(8, 2.5, 8, 9.6); d.poly([(5.4, 7.2), (8, 9.8), (10.6, 7.2)]) },
        "square.and.arrow.down.on.square": ink { d in d.m(5, 7); d.l(3.5, 7); d.l(3.5, 13.5); d.l(12.5, 13.5); d.l(12.5, 7); d.l(11, 7); d.line(8, 2.5, 8, 9.6); d.poly([(5.4, 7.2), (8, 9.8), (10.6, 7.2)]) },
        "tray.and.arrow.down": ink { d in d.m(2.5, 9.5); d.l(2.5, 13); d.l(13.5, 13); d.l(13.5, 9.5); d.l(10.4, 9.5); d.l(9.6, 11); d.l(6.4, 11); d.l(5.6, 9.5); d.path.closeSubpath(); d.line(8, 2.5, 8, 8); d.poly([(5.6, 5.8), (8, 8.2), (10.4, 5.8)]) },
        "arrow.down.app": ink { d in d.rect(2.5, 2.5, 13.5, 13.5, 3); d.line(8, 5, 8, 10.6); d.poly([(5.8, 8.4), (8, 10.6), (10.2, 8.4)]) },
        "app": ink { d in d.rect(2.5, 2.5, 13.5, 13.5, 3) },
        "clock.arrow.circlepath": ink { d in d.m(2.4, 8); d.arc(8, 8, 5.6, 180, 450 - 20); d.poly([(0.9, 6.6), (2.4, 8.4), (4, 6.8)]); d.poly([(8, 5), (8, 8), (10, 9.6)]) },
        "house": ink { d in d.poly([(2.4, 7.6), (8, 2.8), (13.6, 7.6)]); d.poly([(4, 6.6), (4, 13.2), (12, 13.2), (12, 6.6)]); d.line(6.6, 13.2, 6.6, 9.6) },
        "trash": ink { d in d.line(2.8, 4.6, 13.2, 4.6); d.line(6, 4.6, 6, 3); d.line(6, 3, 10, 3); d.line(10, 3, 10, 4.6); d.poly([(4, 4.6), (4.8, 13.4), (11.2, 13.4), (12, 4.6)]); d.line(6.8, 7, 6.8, 11); d.line(9.2, 7, 9.2, 11) },
        "bookmark": ink { d in d.poly([(4.4, 2.6), (11.6, 2.6), (11.6, 13.4), (8, 10.4), (4.4, 13.4)], closed: true) },
        "key.icloud": ink { d in d.circle(5.6, 9.4, 2.8); d.line(8, 7.4, 13.5, 2.5); d.line(11.2, 4.5, 12.8, 6) },
        "key.viewfinder": ink { d in d.circle(6, 8, 2.2); d.line(8.2, 8, 12, 8); d.line(11, 8, 11, 9.6) },
        "keyboard": ink { d in d.rect(1.8, 4, 14.2, 12, 1.8); d.line(4.6, 7, 4.6, 7.05); d.line(8, 7, 8, 7.05); d.line(11.4, 7, 11.4, 7.05); d.line(5, 9.8, 11, 9.8) },
        "terminal": ink { d in d.rect(2, 3, 14, 13, 2); d.poly([(4.8, 6.2), (7, 8), (4.8, 9.8)]); d.line(8.4, 10, 11, 10) },
        "hammer": ink { d in d.line(7, 7, 12.6, 12.6); d.m(3, 6.4); d.l(6.8, 2.6); d.l(10.6, 6.4); d.l(8.6, 8.4); d.l(7, 6.8); d.l(5, 8.4) },
        "bolt": ink { d in d.poly([(9, 2.2), (4.2, 9), (8, 9), (7, 13.8), (11.8, 7), (8, 7)], closed: true) },
        "scissors": ink { d in d.circle(4.4, 11.4, 1.8); d.circle(11.6, 11.4, 1.8); d.line(5.6, 10, 11, 3); d.line(10.4, 10, 5, 3) },
        "cursorarrow.rays": ink { d in d.poly([(4, 3), (4, 12), (6.8, 9.6), (8.6, 13.4), (10, 12.8), (8.2, 9), (11.4, 9)], closed: true) },
        "computermouse": ink { d in d.rect(4.6, 2.6, 11.4, 13.4, 3.4); d.line(8, 2.6, 8, 6.4) },
        "hourglass": ink { d in d.line(4, 2.6, 12, 2.6); d.line(4, 13.4, 12, 13.4); d.poly([(5, 2.6), (5, 5), (8, 8), (5, 11), (5, 13.4)]); d.poly([(11, 2.6), (11, 5), (8, 8), (11, 11), (11, 13.4)]) },
        "timer": ink { d in d.circle(8, 9, 5); d.line(8, 9, 10, 6.6); d.line(6.4, 2.4, 9.6, 2.4) },
        "speedometer": ink { d in d.arc(8, 9.5, 6, 180, 360); d.line(8, 9.5, 11, 6) },
        "bell.badge": ink { d in d.m(3.4, 11.4); d.q(8, 2.8, 4.6, 6.8); d.q(11.4, 6.8, 12.6, 11.4); d.line(3.4, 11.4, 12.6, 11.4); d.line(6.6, 13.4, 9.4, 13.4) },
        "camera.viewfinder": ink { d in d.poly([(2.5, 5.6), (2.5, 2.5), (5.6, 2.5)]); d.poly([(10.4, 2.5), (13.5, 2.5), (13.5, 5.6)]); d.poly([(13.5, 10.4), (13.5, 13.5), (10.4, 13.5)]); d.poly([(5.6, 13.5), (2.5, 13.5), (2.5, 10.4)]); d.circle(8, 8, 2.4) },
        "wand.and.stars": ink { d in d.line(3, 13, 10.4, 5.6); d.line(10.4, 3, 10.4, 5); d.line(9.4, 4, 11.4, 4); d.line(12.6, 8, 12.6, 9.6); d.line(11.8, 8.8, 13.4, 8.8) },
        "network": ink { d in d.circle(8, 8, 6); d.line(2, 8, 14, 8); d.m(8, 2); d.q(8, 14, 5, 8) },
        "internaldrive": ink { d in d.rect(2, 5.6, 14, 11.6, 2.2); d.line(10.8, 8.6, 10.8, 8.65) },
        "play.rectangle": ink { d in d.rect(2, 3.4, 14, 12.6, 2.2); d.poly([(6.8, 6), (10.4, 8), (6.8, 10)], closed: true) },
        "play.slash": ink { d in d.poly([(5.6, 3.6), (12.2, 8), (5.6, 12.4)], closed: true); d.line(2.5, 2.5, 13.5, 13.5) },
        "pip": ink { d in d.rect(2, 3, 14, 13, 2); d.rect(7.6, 7.4, 12.6, 11.4, 1) },
        "pip.exit": ink { d in d.rect(2, 3, 14, 13, 2); d.rect(7.6, 7.4, 12.6, 11.4, 1); d.line(4, 5, 6.4, 7.4) },
        "sidebar.left": ink { d in d.rect(2, 3, 14, 13, 2); d.line(6.4, 3, 6.4, 13) },
        "sidebar.right": ink { d in d.rect(2, 3, 14, 13, 2); d.line(9.6, 3, 9.6, 13) },
        "sidebar.squares.left": ink { d in d.rect(2, 3, 14, 13, 2); d.line(6.4, 3, 6.4, 13); d.line(3.6, 6, 5.2, 6); d.line(3.6, 8.4, 5.2, 8.4) },
        "rectangle.lefthalf.inset.filled.arrow.left": ink { d in d.rect(2, 3, 14, 13, 2); d.line(6.4, 3, 6.4, 13) },
        "rectangle.inset.filled": ink { d in d.rect(2, 3, 14, 13, 2); d.rect(4.6, 5.4, 11.4, 10.6, 0.6) },
        "rectangle.compress.vertical": ink { d in d.line(3, 3, 13, 3); d.line(3, 13, 13, 13); d.poly([(5.8, 5.6), (8, 7.8), (10.2, 5.6)]); d.poly([(5.8, 10.4), (8, 8.2), (10.2, 10.4)]) },
        "rectangle.and.pencil.and.ellipsis": ink { d in d.rect(2, 3, 14, 13, 2); d.line(5, 8, 5, 8.05); d.line(8, 8, 8, 8.05); d.line(11, 8, 11, 8.05) },
        "rectangle.and.text.magnifyingglass": ink { d in d.rect(2, 3, 11, 13, 2); d.circle(10, 9.6, 2.6); d.line(12, 11.6, 14, 13.6) },
        "list.bullet.rectangle": ink { d in d.rect(2, 3, 14, 13, 2); d.line(5.2, 6.4, 5.25, 6.4); d.line(7.4, 6.4, 11, 6.4); d.line(5.2, 9.6, 5.25, 9.6); d.line(7.4, 9.6, 11, 9.6) },
        "text.magnifyingglass": ink { d in d.line(2.5, 4, 9, 4); d.line(2.5, 7.6, 6, 7.6); d.line(2.5, 11.2, 6, 11.2); d.circle(9.6, 9, 2.8); d.line(11.6, 11, 13.8, 13.2) },
        "text.line.first.and.arrowtriangle.forward": ink { d in d.line(3, 4, 13, 4); d.line(3, 8, 8, 8); d.line(3, 12, 13, 12); d.poly([(10, 6), (13, 8), (10, 10)], closed: true) },
        "textformat.size": ink { d in d.poly([(2.5, 12.5), (6, 3.5), (9.5, 12.5)]); d.line(3.8, 9.6, 8.2, 9.6); d.line(11, 7, 14, 7); d.line(12.5, 7, 12.5, 12.5) },
        "textformat.size.larger": ink { d in d.poly([(2.5, 12.5), (6, 3.5), (9.5, 12.5)]); d.line(3.8, 9.6, 8.2, 9.6); d.line(11, 7, 14, 7); d.line(12.5, 5.5, 12.5, 8.5) },
        "textformat.abc.dottedunderline": ink { d in d.poly([(2.5, 10), (5, 3.5), (7.5, 10)]); d.line(3.4, 7.8, 6.6, 7.8); d.line(10, 3.5, 10, 10); d.line(2.5, 13, 13.5, 13) },
        "bold": ink { d in d.m(5, 3); d.l(5, 13); d.m(5, 3); d.l(9, 3); d.q(11, 5.4, 11, 3); d.q(9, 8, 11, 8); d.l(5, 8); d.m(5, 8); d.l(9.6, 8); d.q(12, 10.6, 12, 8); d.q(9.6, 13, 12, 13); d.l(5, 13) },
        "number": ink { d in d.line(6, 3, 5, 13); d.line(11, 3, 10, 13); d.line(3, 6.4, 13, 6.4); d.line(2.6, 9.8, 12.6, 9.8) },
        "doc.plaintext": ink { d in d.poly([(4, 2.5), (9, 2.5), (12, 5.6), (12, 13.5), (4, 13.5)], closed: true); d.line(6, 8.4, 10, 8.4); d.line(6, 11, 10, 11) },
        "doc.richtext": ink { d in d.poly([(4, 2.5), (9, 2.5), (12, 5.6), (12, 13.5), (4, 13.5)], closed: true); d.line(6, 8, 10, 8); d.line(6, 10.7, 10, 10.7) },
        "translate": ink { d in d.line(2.5, 4.4, 10, 4.4); d.line(6.2, 3, 6.2, 4.4); d.m(3.6, 4.4); d.q(7, 9.6, 8.6, 7.4); d.poly([(8.8, 13.4), (11.2, 7.6), (13.6, 13.4)]); d.line(9.6, 11.6, 12.8, 11.6) },
        "wind": ink { d in d.line(2, 6, 10, 6); d.q(12.6, 3.6, 10, 6); d.q(12.4, 6, 11.6, 5); d.line(2, 9.6, 12, 9.6); d.line(2, 12.6, 8, 12.6) },
        "shift": ink { d in d.poly([(8, 2.8), (13.4, 8.6), (10.2, 8.6), (10.2, 13), (5.8, 13), (5.8, 8.6), (2.6, 8.6)], closed: true) },
        "plus.square": ink { d in d.rect(2.5, 2.5, 13.5, 13.5, 2.2); d.line(8, 5.4, 8, 10.6); d.line(5.4, 8, 10.6, 8) },
        "plus.rectangle.on.rectangle": ink { d in d.rect(2.5, 5, 10.5, 13.5, 1.8); d.m(5.5, 3); d.l(13.5, 3); d.l(13.5, 10.5); d.line(6.5, 7.6, 6.5, 11); d.line(4.8, 9.3, 8.2, 9.3) },
        "arrow.triangle.branch": ink { d in d.circle(4.6, 3.8, 1.5); d.circle(4.6, 12.2, 1.5); d.circle(11.4, 6.2, 1.5); d.line(4.6, 5.4, 4.6, 10.6); d.m(11.4, 7.8); d.q(4.6, 8.6, 11.4, 10) },
    ]
}
