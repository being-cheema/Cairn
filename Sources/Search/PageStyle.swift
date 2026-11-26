import AppKit
import SwiftUI
import WebKit

// Inspect Style, on the site card: the fonts, type sizes and main colours a
// page is drawn with, to copy as CSS custom properties or SwiftUI colours.
//
// Read once when asked, from computed styles, by Cairn's script in Cairn's
// own world; nothing is added to the page and nothing is kept. What a page
// calls its fonts is the page's word, so only what a font's name is made of
// goes into what you copy: it can't close a quote and add a rule.

struct PageStyle: Equatable {
    struct Colour: Equatable, Hashable {
        let red, green, blue: Int
        var hex: String { String(format: "#%02x%02x%02x", red, green, blue) }
    }

    struct Size: Equatable {
        let pixels: Double
        let weight: Int
        var said: String { PageStyle.number(pixels) + "px" + (weight == 400 ? "" : " / \(weight)") }
    }

    /// Each a stack as CSS writes one, the most used first.
    var fonts: [String] = []
    /// Largest first.
    var sizes: [Size] = []
    /// The most seen first.
    var colours: [Colour] = []

    var isEmpty: Bool { fonts.isEmpty && sizes.isEmpty && colours.isEmpty }

    static let mostFonts = 4, mostSizes = 10, mostColours = 8

    static func number(_ value: Double) -> String {
        let tenth = (value * 10).rounded() / 10
        return tenth == tenth.rounded() ? String(Int(tenth)) : String(tenth)
    }

    private static let generic: Set<String> = [
        "serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui", "ui-serif", "ui-sans-serif",
        "ui-monospace", "ui-rounded", "math", "emoji", "-apple-system", "BlinkMacSystemFont",
    ]

    /// A computed font-family as it may be pasted: each name stripped to
    /// what names are made of, and quoted unless it is CSS's own word.
    static func stack(_ raw: String) -> String? {
        let names = raw.prefix(600).split(separator: ",").prefix(6).compactMap { part -> String? in
            let kept = String(part.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || " -_.".unicodeScalars.contains($0)
            }.map(Character.init)).trimmingCharacters(in: .whitespaces)
            guard !kept.isEmpty, kept.count <= 80 else { return nil }
            return generic.contains(kept) ? kept : "\"\(kept)\""
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// From what the script sends: [name, how much] for fonts, [pixels,
    /// weight, how much] for sizes, [r, g, b, how much] for colours.
    static func from(_ value: Any?) -> PageStyle? {
        guard let text = value as? String, let data = text.data(using: .utf8),
              let out = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var style = PageStyle()
        for entry in out["fonts"] as? [[Any]] ?? [] where style.fonts.count < mostFonts {
            guard let stack = (entry.first as? String).flatMap(stack), !style.fonts.contains(stack) else { continue }
            style.fonts.append(stack)
        }
        for entry in out["sizes"] as? [[Double]] ?? [] where style.sizes.count < mostSizes {
            guard entry.count >= 2, entry[0] > 0, entry[0] < 1000, entry[1] >= 1, entry[1] <= 1000 else { continue }
            let size = Size(pixels: entry[0], weight: Int(entry[1]))
            if !style.sizes.contains(size) { style.sizes.append(size) }
        }
        style.sizes.sort { ($0.pixels, $0.weight) > ($1.pixels, $1.weight) }
        for entry in out["colours"] as? [[Double]] ?? [] where style.colours.count < mostColours {
            guard entry.count >= 3, entry.prefix(3).allSatisfy({ (0...255).contains($0) }) else { continue }
            let colour = Colour(red: Int(entry[0]), green: Int(entry[1]), blue: Int(entry[2]))
            if !style.colours.contains(colour) { style.colours.append(colour) }
        }
        return style
    }

    var css: String {
        var lines = [":root {"]
        for (index, font) in fonts.enumerated() { lines.append("  --font-\(index + 1): \(font);") }
        for (index, size) in sizes.enumerated() {
            lines.append("  --size-\(index + 1): \(Self.number(size.pixels))px;")
            lines.append("  --weight-\(index + 1): \(size.weight);")
        }
        for (index, colour) in colours.enumerated() { lines.append("  --color-\(index + 1): \(colour.hex);") }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    var swiftUI: String {
        colours.enumerated().map { index, colour in
            "let color\(index + 1) = Color(red: \(colour.red) / 255, green: \(colour.green) / 255, blue: \(colour.blue) / 255) // \(colour.hex)"
        }.joined(separator: "\n") + "\n"
    }

    @MainActor
    static func read(_ web: WKWebView, _ done: @escaping (PageStyle?) -> Void) {
        web.evaluateJavaScript(PageScripts.styles(), in: nil, in: Web.world) { done(from(try? $0.get())) }
    }
}

extension PageScripts {
    static func styles() -> String {
        call(#"""
        (function () {
          var fonts = new Map(), sizes = new Map(), colours = new Map();
          function add(map, key, much) { map.set(key, (map.get(key) || 0) + much); }
          // Any way CSS writes a colour, drawn on a dot of a canvas that is
          // never in the page, and read back as red, green and blue.
          var dot = document.createElement('canvas');
          dot.width = dot.height = 1;
          var brush = dot.getContext('2d', { willReadFrequently: true }), read = new Map();
          function rgb(said) {
            if (read.has(said)) return read.get(said);
            var out = null;
            if (brush && said) {
              brush.clearRect(0, 0, 1, 1);
              brush.fillStyle = '#000';
              brush.fillStyle = said;
              brush.fillRect(0, 0, 1, 1);
              var p = brush.getImageData(0, 0, 1, 1).data;
              // Mostly see-through is no colour of the page's own.
              if (p[3] >= 128) out = p[0] + ',' + p[1] + ',' + p[2];
            }
            read.set(said, out);
            return out;
          }
          var all = document.body ? [document.documentElement, document.body].concat(
            Array.prototype.slice.call(document.body.querySelectorAll('*'), 0, 4000)) : [];
          all.forEach(function (el) {
            if (!visible(el)) return;
            var how = getComputedStyle(el), words = 0;
            for (var n = el.firstChild; n; n = n.nextSibling) if (n.nodeType === 3) words += n.nodeValue.trim().length;
            if (words) {
              add(fonts, how.fontFamily, words);
              add(sizes, parseFloat(how.fontSize) + ' ' + (parseInt(how.fontWeight, 10) || 400), words);
              var ink = rgb(how.color);
              if (ink) add(colours, ink, words * 40);
            }
            var r = el.getBoundingClientRect(), ground = rgb(how.backgroundColor);
            // By the area it covers, no more than a screen's worth.
            if (ground) add(colours, ground, Math.min(r.width * r.height, innerWidth * innerHeight) / 100);
          });
          function top(map, most) {
            return Array.from(map.entries()).sort(function (a, b) { return b[1] - a[1]; }).slice(0, most);
          }
          return JSON.stringify({
            fonts: top(fonts, 8),
            sizes: top(sizes, 10).map(function (e) { return e[0].split(' ').map(Number).concat(e[1]); }),
            colours: top(colours, 12).map(function (e) { return e[0].split(',').map(Number).concat(e[1]); })
          });
        })
        """#, [])
    }
}

/// The site card's step in: what was found, and the two ways to take it.
struct SiteStyleCard: View {
    @ObservedObject var tab: Tab
    let back: () -> Void

    @State private var style: PageStyle?
    @State private var failed = false
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Style")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            if let style, !style.isEmpty {
                found(style)
                HStack(spacing: 6) {
                    Button(copied == "css" ? "Copied" : "Copy CSS Variables") { copy(style.css, "css") }
                    Button(copied == "swift" ? "Copied" : "Copy SwiftUI Colors") { copy(style.swiftUI, "swift") }
                        .disabled(style.colours.isEmpty)
                }
                .controlSize(.small)
            } else {
                Text(failed || style != nil ? "Nothing to read on this page" : "Reading…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            Button("Back", action: back).buttonStyle(.plain).font(MenuMetrics.font)
        }
        .frame(width: 260, alignment: .leading)
        .padding(.horizontal, MenuMetrics.text)
        .padding(.vertical, 4)
        .onAppear {
            guard let web = tab.built, !tab.asleep else { failed = true; return }
            PageStyle.read(web) {
                style = $0
                failed = $0 == nil
            }
        }
    }

    @ViewBuilder private func found(_ style: PageStyle) -> some View {
        ForEach(style.fonts, id: \.self) { words($0) }
        words(style.sizes.map(\.said).joined(separator: ", "))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 4) {
            ForEach(style.colours, id: \.self) { colour in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: Double(colour.red) / 255, green: Double(colour.green) / 255, blue: Double(colour.blue) / 255))
                        .frame(width: 12, height: 12)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(nsColor: .separatorColor)))
                    Text(verbatim: colour.hex).font(.system(size: 10.5).monospaced())
                }
            }
        }
    }

    private func words(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundStyle(Color(nsColor: .labelColor))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ text: String, _ which: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = which
    }
}
