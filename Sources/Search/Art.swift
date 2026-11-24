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

/// A picture for a quiet place, or the coral circle when there is none. In a
/// dark window it sits on a paper tile: the ink of the drawing is black.
struct ArtPicture: View {
    let name: String
    var size: CGFloat = 96
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let image = Art.image(name) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(scheme == .dark ? size * 0.08 : 0)
                    .background {
                        if scheme == .dark {
                            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                                .fill(Color(red: 0.98, green: 0.97, blue: 0.95))
                        }
                    }
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
