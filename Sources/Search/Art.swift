import SwiftUI
import AppKit

// The pictures in the app's quiet places: an empty list, a welcome, an action
// held for you.
//
// They are the owner's own, from icons8, and not MIT: they live in
// Local/Art/ (never committed), ./build.sh copies them into the app it builds
// on this Mac, and a DMG or ship refuses to run while that folder has any.
// So a clone of the repo has none, and every place that asks for one draws a
// plain coral circle instead and is otherwise the same.

enum Art {
    /// The picture called `name` (Local/Art/<name>.png), if this build has it.
    @MainActor static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached.image }
        let found = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Art")
            .flatMap { NSImage(contentsOf: $0) }
        cache[name] = Held(image: found)
        return found
    }

    private struct Held { let image: NSImage? }
    @MainActor private static var cache: [String: Held] = [:]
}

extension Art {
    /// The picture for a dark window: its black ink turned light and its paper
    /// let through, the coral kept. A paper-white tile pasted on the charcoal
    /// was the brightest thing on screen; this lets the picture sit on
    /// whatever it is placed on. Made once per picture.
    @MainActor static func darkImage(_ name: String) -> NSImage? {
        if let cached = darkCache[name] { return cached.image }
        let made = image(name).flatMap(inverted)
        darkCache[name] = Held(image: made)
        return made
    }

    @MainActor private static var darkCache: [String: Held] = [:]

    private static func inverted(_ source: NSImage) -> NSImage? {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        // The light ink: the dark theme's own, near white.
        let ink: CGFloat = 0.93
        for at in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = CGFloat(pixels[at + 3]) / 255
            guard alpha > 0 else { continue }
            // Premultiplied in, so the colour is divided back out first.
            let red = min(1, CGFloat(pixels[at]) / 255 / alpha)
            let green = min(1, CGFloat(pixels[at + 1]) / 255 / alpha)
            let blue = min(1, CGFloat(pixels[at + 2]) / 255 / alpha)
            let light = (red + green + blue) / 3
            let chroma = max(red, green, blue) - min(red, green, blue)
            // Grey is ink or paper: the darker, the more of it stays, and
            // white goes clear. Colour is kept as drawn.
            let keep = min(1, chroma / 0.10)
            let neutral = alpha * (1 - light)
            let outAlpha = keep * alpha + (1 - keep) * neutral
            guard outAlpha > 0 else { pixels[at] = 0; pixels[at + 1] = 0; pixels[at + 2] = 0; pixels[at + 3] = 0; continue }
            let channels = [red, green, blue].map { color -> CGFloat in
                let mixed = keep * color + (1 - keep) * ink
                return mixed * outAlpha
            }
            for (offset, value) in channels.enumerated() { pixels[at + offset] = UInt8(max(0, min(255, value * 255 + 0.5))) }
            pixels[at + 3] = UInt8(max(0, min(255, outAlpha * 255 + 0.5)))
        }
        let made: CGImage? = pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        return made.map { NSImage(cgImage: $0, size: source.size) }
    }
}

/// A picture for a quiet place, or the coral circle when there is none. In a
/// dark window its ink is turned light and its paper let through (see
/// `Art.darkImage`), so it rests on the window and not on a white tile.
struct ArtPicture: View {
    let name: String
    var size: CGFloat = 96
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let image = scheme == .dark ? (Art.darkImage(name) ?? Art.image(name)) : Art.image(name) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Circle().fill(Palette.accent.opacity(0.18))
                    .overlay(Circle().strokeBorder(Palette.accent.opacity(0.5), lineWidth: 1.5))
                    .padding(size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
