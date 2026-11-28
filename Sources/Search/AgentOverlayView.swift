import AppKit
import QuartzCore
import WebKit

// Where the agent's hand is, drawn over its page by the app: a coral ring on
// what it is about to touch, a short word for what it is doing, and, while a
// question waits for you, an outline round the very thing it asks about.
//
// A view of the app's own, laid on the web view. Nothing goes into the page:
// no element, no style, nothing a site's script could see or lay out around.
// It takes no clicks (hitTest), and a picture of the page taken for the agent
// (takeSnapshot) is WebKit's drawing alone, without it. The words quote the
// page's own name for a control, which is data, never an instruction.

final class AgentOverlayView: NSView {
    /// How long a mark stays after the last thing done.
    static let lingers: TimeInterval = 1.2

    private let ring = CAShapeLayer()
    private let dot = CALayer()
    private let pill = CALayer()
    private let words = CATextLayer()
    private var fading: DispatchWorkItem?
    /// Held on something you are being asked about: it stays till answered.
    private(set) var spotlit = false
    /// For tests and the bench: what it says now, and where (view points).
    private(set) var saying = ""
    private(set) var marked: CGRect?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        ring.fillColor = nil
        ring.lineWidth = 2
        dot.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        dot.cornerRadius = 6
        dot.borderWidth = 2
        pill.cornerRadius = 9
        pill.borderWidth = 1
        words.fontSize = 11.5
        words.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        words.truncationMode = .end
        pill.addSublayer(words)
        for each in [ring, pill, dot] as [CALayer] {
            each.opacity = 0
            layer?.addSublayer(each)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// The overlay on a page's view, made the first time.
    static func over(_ web: WKWebView) -> AgentOverlayView {
        if let there = web.subviews.lazy.compactMap({ $0 as? AgentOverlayView }).first { return there }
        let made = AgentOverlayView(frame: web.bounds)
        web.addSubview(made)
        return made
    }

    static func remove(from web: WKWebView) {
        web.subviews.compactMap { $0 as? AgentOverlayView }.forEach { $0.removeFromSuperview() }
    }

    /// A box in the page's CSS pixels as one in the view's points. Nil when
    /// it isn't a box: four finite numbers with some size.
    static func place(_ box: [Double], zoom: CGFloat) -> CGRect? {
        guard box.count == 4, box.allSatisfy(\.isFinite), box[2] > 0, box[3] > 0 else { return nil }
        return CGRect(x: box[0] * zoom, y: box[1] * zoom, width: box[2] * zoom, height: box[3] * zoom)
    }

    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func colour() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let coral = NSColor(Palette.accent).cgColor
            ring.strokeColor = coral
            dot.backgroundColor = coral
            dot.borderColor = NSColor.white.cgColor
            pill.backgroundColor = Palette.NS.ground.withAlphaComponent(0.96).cgColor
            pill.borderColor = Palette.NS.ink.withAlphaComponent(0.14).cgColor
            words.foregroundColor = Palette.NS.ink.cgColor
        }
        words.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Shows `text` by `box` (view points), or at the top with no box.
    /// `click` adds a ripple at its middle. A spotlight holds, pulsing, until
    /// `clear`; anything else fades.
    func show(_ text: String, at box: CGRect?, click: Bool = false, spotlight: Bool = false) {
        // A question's outline isn't moved by whatever else goes on.
        if spotlit, !spotlight { return }
        fading?.cancel()
        spotlit = spotlight
        saying = text
        marked = box
        colour()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium)])
        let wide = min(ceil(size.width) + 22, max(bounds.width - 16, 80))
        var origin = CGPoint(x: (bounds.width - wide) / 2, y: 10)
        if let box {
            // Under the thing, or over it where there is no room under.
            let under = box.maxY + 10
            origin = CGPoint(x: min(max(box.minX, 8), max(bounds.width - wide - 8, 8)),
                             y: under + 24 < bounds.height ? under : max(box.minY - 34, 8))
        }
        pill.frame = CGRect(origin: origin, size: CGSize(width: wide, height: 24))
        words.frame = CGRect(x: 11, y: 4.5, width: wide - 22, height: 16)
        words.string = text
        pill.opacity = 1
        ring.removeAllAnimations()
        if let box {
            ring.path = CGPath(roundedRect: box.insetBy(dx: -4, dy: -4), cornerWidth: 7, cornerHeight: 7, transform: nil)
            ring.lineWidth = spotlight ? 3 : 2
            ring.opacity = 1
        } else {
            ring.opacity = 0
        }
        CATransaction.commit()

        if let box {
            let middle = CGPoint(x: box.midX, y: box.midY)
            if !still, dot.opacity > 0 {
                let move = CASpringAnimation(keyPath: "position")
                move.fromValue = dot.presentation()?.position ?? dot.position
                move.toValue = middle
                move.damping = 18
                move.stiffness = 220
                move.duration = move.settlingDuration
                dot.add(move, forKey: "move")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.position = middle
            dot.opacity = spotlight ? 0 : 1
            CATransaction.commit()
            if click, !still { ripple(at: middle) }
        } else {
            dot.opacity = 0
        }
        if spotlight {
            if !still {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.35
                pulse.duration = 0.8
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                ring.add(pulse, forKey: "pulse")
            }
            return
        }
        let fade = DispatchWorkItem { [weak self] in self?.clear() }
        fading = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingers, execute: fade)
    }

    private func ripple(at point: CGPoint) {
        let circle = CAShapeLayer()
        circle.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
        circle.position = point
        circle.fillColor = nil
        circle.strokeColor = ring.strokeColor
        circle.lineWidth = 2
        circle.opacity = 0
        layer?.addSublayer(circle)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1.6
        let leave = CABasicAnimation(keyPath: "opacity")
        leave.fromValue = 0.9
        leave.toValue = 0
        let both = CAAnimationGroup()
        both.animations = [grow, leave]
        both.duration = 0.45
        circle.add(both, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { circle.removeFromSuperlayer() }
    }

    func clear() {
        fading?.cancel()
        fading = nil
        spotlit = false
        saying = ""
        marked = nil
        ring.removeAllAnimations()
        CATransaction.begin()
        if still { CATransaction.setDisableActions(true) } else { CATransaction.setAnimationDuration(0.25) }
        for each in [ring, pill, dot] as [CALayer] { each.opacity = 0 }
        CATransaction.commit()
    }
}


/// Numbered coral badges over two to four controls of an agent's own page,
/// for the person to click one (AgentControl.disambiguate). The app's own
/// view: nothing goes into the page. Only a badge takes a click; the rest of
/// the view lets the page have it. A badge answers only to a fresh click of
/// the person's (AgentRules.isClick, in AgentControl.choose), never to a key
/// or an accessibility press.
final class AgentChoiceView: NSView {
    final class Badge: NSView {
        let number: Int
        init(number: Int, centre: CGPoint) {
            self.number = number
            super.init(frame: CGRect(x: centre.x - 13, y: centre.y - 13, width: 26, height: 26))
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }
        // No accessibility action: a press that isn't a click is no answer.
        override func isAccessibilityElement() -> Bool { false }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) { AgentControl.shared.choose(number: number, event: event, on: self) }
        override func draw(_ dirty: NSRect) {
            NSColor(Palette.accent).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
            let text = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
        }
    }

    private(set) var badges: [Badge] = []
    private var outlines: [CGRect] = []

    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        badges.first { $0.frame.contains(convert(point, from: superview)) }
    }

    /// Put over a page's view: a badge at the top-left corner of each box
    /// (view points), and an outline round it.
    static func show(on web: WKWebView, boxes: [CGRect]) -> AgentChoiceView {
        web.subviews.compactMap { $0 as? AgentChoiceView }.forEach { $0.removeFromSuperview() }
        let view = AgentChoiceView(frame: web.bounds)
        view.autoresizingMask = [.width, .height]
        view.outlines = boxes
        for (index, box) in boxes.enumerated() {
            let badge = Badge(number: index + 1, centre: CGPoint(x: max(box.minX, 14), y: max(box.minY, 14)))
            view.badges.append(badge)
            view.addSubview(badge)
        }
        web.addSubview(view)
        return view
    }

    override func draw(_ dirty: NSRect) {
        NSColor(Palette.accent).setStroke()
        for box in outlines {
            let path = NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6)
            path.lineWidth = 2
            path.stroke()
        }
    }
}
