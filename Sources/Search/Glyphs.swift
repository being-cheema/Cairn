import SwiftUI

// The app's own line icons: one ink line, round ends, drawn on a 16-point
// grid, in place of the system's symbols, whose stiff geometric weight is the
// one thing about the chrome that never looked hand-made.
//
// `Ink("xmark", size: 12)` takes the symbol's own name, so a place that wore a
// system symbol changes by one word. A name with no drawing here is still the
// system's symbol, sized the same, so nothing is ever missing: the set grows a
// name at a time. Filled and circled symbols are not drawn yet.

struct Ink: View {
    let name: String
    var size: CGFloat

    init(_ name: String, size: CGFloat = 13) {
        self.name = name
        self.size = size
    }

    var body: some View {
        if let glyph = InkGlyph.drawn[name] {
            InkShape(glyph: glyph)
                .stroke(style: StrokeStyle(lineWidth: max(1.2, size * 0.105), lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        } else {
            Image(systemName: name).font(.system(size: size))
        }
    }
}

private struct InkShape: Shape {
    let glyph: InkGlyph
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        return glyph.draw(rect.midX - 8 * s, rect.midY - 8 * s, s)
    }
}

struct InkGlyph {
    /// Draws on a 16 × 16 grid whose corner is (x, y) and whose point is `s`.
    let draw: (CGFloat, CGFloat, CGFloat) -> Path

    private static func lines(_ strokes: [[(CGFloat, CGFloat)]]) -> InkGlyph {
        InkGlyph { x, y, s in
            var p = Path()
            for stroke in strokes {
                guard let first = stroke.first else { continue }
                p.move(to: CGPoint(x: x + first.0 * s, y: y + first.1 * s))
                if stroke.count == 1 { p.addLine(to: CGPoint(x: x + first.0 * s + 0.01, y: y + first.1 * s)) }
                for pt in stroke.dropFirst() { p.addLine(to: CGPoint(x: x + pt.0 * s, y: y + pt.1 * s)) }
            }
            return p
        }
    }

    private static func with(_ base: InkGlyph, _ extra: @escaping (inout Path, CGFloat, CGFloat, CGFloat) -> Void) -> InkGlyph {
        InkGlyph { x, y, s in
            var p = base.draw(x, y, s)
            extra(&p, x, y, s)
            return p
        }
    }

    private static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, in p: inout Path, _ x: CGFloat, _ y: CGFloat, _ s: CGFloat) {
        p.addEllipse(in: CGRect(x: x + (cx - r) * s, y: y + (cy - r) * s, width: 2 * r * s, height: 2 * r * s))
    }

    private static let glass = InkGlyph { x, y, s in
        var p = Path()
        circle(7, 7, 4.5, in: &p, x, y, s)
        p.move(to: CGPoint(x: x + 10.4 * s, y: y + 10.4 * s))
        p.addLine(to: CGPoint(x: x + 13.5 * s, y: y + 13.5 * s))
        return p
    }

    private static let asterisk = InkGlyph { x, y, s in
        // Three strokes through one point, none quite the length of another:
        // a mark made by a hand, not a compass.
        var p = Path()
        let spokes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(8, 2.2, 8, 13.6), (3.2, 4.9, 12.9, 11.2), (3.0, 11.0, 12.7, 5.1)]
        for sp in spokes {
            p.move(to: CGPoint(x: x + sp.0 * s, y: y + sp.1 * s))
            p.addLine(to: CGPoint(x: x + sp.2 * s, y: y + sp.3 * s))
        }
        return p
    }

    static let drawn: [String: InkGlyph] = [
        "xmark": lines([[(3.5, 3.5), (12.5, 12.5)], [(12.5, 3.5), (3.5, 12.5)]]),
        "plus": lines([[(8, 3), (8, 13)], [(3, 8), (13, 8)]]),
        "checkmark": lines([[(3, 8.6), (6.6, 12), (13, 4.6)]]),
        "chevron.right": lines([[(6, 3), (11, 8), (6, 13)]]),
        "chevron.down": lines([[(3, 6), (8, 11), (13, 6)]]),
        "chevron.up.chevron.down": lines([[(4.5, 6.4), (8, 3), (11.5, 6.4)], [(4.5, 9.6), (8, 13), (11.5, 9.6)]]),
        "arrow.down": lines([[(8, 3), (8, 13)], [(4, 9), (8, 13), (12, 9)]]),
        "arrow.right": lines([[(3, 8), (13, 8)], [(9, 4), (13, 8), (9, 12)]]),
        "ellipsis": lines([[(3.5, 8)], [(8, 8)], [(12.5, 8)]]),
        "magnifyingglass": glass,
        "plus.magnifyingglass": with(glass) { p, x, y, s in
            p.move(to: CGPoint(x: x + 7 * s, y: y + 5 * s)); p.addLine(to: CGPoint(x: x + 7 * s, y: y + 9 * s))
            p.move(to: CGPoint(x: x + 5 * s, y: y + 7 * s)); p.addLine(to: CGPoint(x: x + 9 * s, y: y + 7 * s))
        },
        "folder": InkGlyph { x, y, s in
            var p = Path()
            p.move(to: CGPoint(x: x + 2 * s, y: y + 11.5 * s))
            p.addLine(to: CGPoint(x: x + 2 * s, y: y + 4.8 * s))
            p.addQuadCurve(to: CGPoint(x: x + 3.3 * s, y: y + 3.5 * s), control: CGPoint(x: x + 2 * s, y: y + 3.5 * s))
            p.addLine(to: CGPoint(x: x + 6.4 * s, y: y + 3.5 * s))
            p.addLine(to: CGPoint(x: x + 7.9 * s, y: y + 5.4 * s))
            p.addLine(to: CGPoint(x: x + 12.7 * s, y: y + 5.4 * s))
            p.addQuadCurve(to: CGPoint(x: x + 14 * s, y: y + 6.7 * s), control: CGPoint(x: x + 14 * s, y: y + 5.4 * s))
            p.addLine(to: CGPoint(x: x + 14 * s, y: y + 11.7 * s))
            p.addQuadCurve(to: CGPoint(x: x + 12.7 * s, y: y + 13 * s), control: CGPoint(x: x + 14 * s, y: y + 13 * s))
            p.addLine(to: CGPoint(x: x + 3.5 * s, y: y + 13 * s))
            p.addQuadCurve(to: CGPoint(x: x + 2 * s, y: y + 11.5 * s), control: CGPoint(x: x + 2 * s, y: y + 13 * s))
            return p
        },
        "doc.text": InkGlyph { x, y, s in
            var p = Path()
            p.move(to: CGPoint(x: x + 4 * s, y: y + 2.5 * s))
            p.addLine(to: CGPoint(x: x + 9 * s, y: y + 2.5 * s))
            p.addLine(to: CGPoint(x: x + 12 * s, y: y + 5.6 * s))
            p.addLine(to: CGPoint(x: x + 12 * s, y: y + 13.5 * s))
            p.addLine(to: CGPoint(x: x + 4 * s, y: y + 13.5 * s))
            p.closeSubpath()
            for yy: CGFloat in [8, 10.7] {
                p.move(to: CGPoint(x: x + 6 * s, y: y + yy * s)); p.addLine(to: CGPoint(x: x + 10 * s, y: y + yy * s))
            }
            return p
        },
        "globe": InkGlyph { x, y, s in
            var p = Path()
            circle(8, 8, 6, in: &p, x, y, s)
            p.addEllipse(in: CGRect(x: x + 5.2 * s, y: y + 2 * s, width: 5.6 * s, height: 12 * s))
            p.move(to: CGPoint(x: x + 2 * s, y: y + 8 * s)); p.addLine(to: CGPoint(x: x + 14 * s, y: y + 8 * s))
            return p
        },
        "eye.slash": InkGlyph { x, y, s in
            var p = Path()
            p.move(to: CGPoint(x: x + 1.5 * s, y: y + 8 * s))
            p.addQuadCurve(to: CGPoint(x: x + 14.5 * s, y: y + 8 * s), control: CGPoint(x: x + 8 * s, y: y + 1.5 * s))
            p.addQuadCurve(to: CGPoint(x: x + 1.5 * s, y: y + 8 * s), control: CGPoint(x: x + 8 * s, y: y + 14.5 * s))
            circle(8, 8, 1.9, in: &p, x, y, s)
            p.move(to: CGPoint(x: x + 3 * s, y: y + 13 * s)); p.addLine(to: CGPoint(x: x + 13 * s, y: y + 3 * s))
            return p
        },
        "exclamationmark.triangle": InkGlyph { x, y, s in
            var p = Path()
            p.move(to: CGPoint(x: x + 8 * s, y: y + 2.4 * s))
            p.addLine(to: CGPoint(x: x + 14.2 * s, y: y + 13 * s))
            p.addLine(to: CGPoint(x: x + 1.8 * s, y: y + 13 * s))
            p.closeSubpath()
            p.move(to: CGPoint(x: x + 8 * s, y: y + 6.6 * s)); p.addLine(to: CGPoint(x: x + 8 * s, y: y + 9.6 * s))
            p.move(to: CGPoint(x: x + 8 * s, y: y + 11.2 * s)); p.addLine(to: CGPoint(x: x + 8 * s, y: y + 11.21 * s))
            return p
        },
        "key": InkGlyph { x, y, s in
            var p = Path()
            circle(5, 10.5, 2.6, in: &p, x, y, s)
            p.move(to: CGPoint(x: x + 6.9 * s, y: y + 8.6 * s)); p.addLine(to: CGPoint(x: x + 13 * s, y: y + 2.5 * s))
            p.move(to: CGPoint(x: x + 11 * s, y: y + 4.5 * s)); p.addLine(to: CGPoint(x: x + 13 * s, y: y + 6.5 * s))
            return p
        },
        // The system's sparkle is the mark of every "AI" button there is; this
        // is a hand-made asterisk instead.
        "sparkles": asterisk,
    ]
}
