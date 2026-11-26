import PDFKit
import Vision
import WebKit

// Reading what a page's own text doesn't say: a PDF on screen, with PDFKit,
// and the words in a picture, with Vision. Both on this Mac: nothing is sent
// anywhere to be read.
//
// For an agent, a PDF's words are the page's like any other (Quarantine), and
// a picture is read only after the same blacking out as a screenshot
// (AgentControl.picture).

enum PDFPages {
    /// A bigger file than this isn't read.
    static let largest = 60_000_000
    static let mostPages = 2_000
    static let mostHeadings = 200

    struct Heading: Equatable {
        let title: String
        let level: Int
        /// From 1; 0 when the heading points nowhere in the document.
        let page: Int
    }

    struct Contents: Equatable {
        var pages: [String]
        var outline: [Heading]
        /// How many it has, which may be more than were read.
        var count: Int
    }

    enum Failure: Error, Equatable { case notPDF, locked }

    static func parse(_ data: Data) -> Result<Contents, Failure> {
        guard let document = PDFDocument(data: data) else { return .failure(.notPDF) }
        guard !document.isLocked else { return .failure(.locked) }
        var pages: [String] = []
        for index in 0..<min(document.pageCount, mostPages) {
            pages.append(autoreleasepool { document.page(at: index)?.string ?? "" })
        }
        var outline: [Heading] = []
        func walk(_ item: PDFOutline, _ level: Int) {
            guard level <= 6 else { return }
            for index in 0..<item.numberOfChildren {
                guard outline.count < mostHeadings, let child = item.child(at: index) else { return }
                let page = child.destination?.page.map { document.index(for: $0) + 1 } ?? 0
                outline.append(Heading(title: String((child.label ?? "").prefix(200)), level: level, page: page))
                walk(child, level + 1)
            }
        }
        if let root = document.outlineRoot { walk(root, 1) }
        return .success(Contents(pages: pages, outline: outline, count: document.pageCount))
    }

    /// A handle that names one page, such as p1.pdf.page3. It names it for
    /// reading: there is nothing in a PDF to click or type into.
    static func handle(_ page: String, _ number: Int) -> String { "\(page).pdf.page\(number)" }

    /// What read_page gives for a PDF. `from` and `longest` count characters
    /// over the pages end to end, as text_offset and max_text do for a page.
    static func answer(_ contents: Contents, page: String, longest: Int, from: Int, text: Bool) -> [String: Any] {
        var out: [String: Any] = ["pdf": true, "pageCount": contents.count, "nodes": [[String: Any]](), "nodesTruncated": false]
        out["outline"] = contents.outline.map { heading -> [String: Any] in
            var entry: [String: Any] = ["title": Quarantine.label(heading.title), "level": heading.level]
            if heading.page > 0 { entry["handle"] = handle(page, heading.page) }
            return entry
        }
        guard text else { return out }
        var shown: [[String: Any]] = []
        var before = 0, left = longest
        for (index, words) in contents.pages.enumerated() {
            let length = words.count
            defer { before += length }
            let skip = max(from - before, 0)
            guard left > 0, skip < length else { continue }
            let piece = String(words.dropFirst(skip).prefix(left))
            left -= piece.count
            shown.append(["handle": handle(page, index + 1), "page": index + 1, "text": Quarantine.fence(piece)])
        }
        let total = contents.pages.reduce(0) { $0 + $1.count }
        out["pages"] = shown
        out["textLength"] = total
        out["textOffset"] = from
        out["textTruncated"] = from + longest < total || contents.count > contents.pages.count
        out["nextTextOffset"] = from + longest < total ? from + longest : NSNull()
        return out
    }

    /// The bytes of the PDF a view is showing, from the view itself: nothing
    /// is fetched again, so no second request goes out and no rule about
    /// where a tab may go is stepped round. Only for a view whose document
    /// says it is a PDF.
    @MainActor
    static func data(shownIn web: WKWebView, _ done: @escaping @MainActor (Data?) -> Void) {
        web.createWebArchiveData { result in
            MainActor.assumeIsolated {
                guard case .success(let archive) = result else { return done(nil) }
                done(document(in: archive))
            }
        }
    }

    /// In a web archive of such a view the main resource is WebKit's own
    /// page around the document, and the document is the subresource at the
    /// same address (PagePerceptionTests holds WebKit to that).
    static func document(in archive: Data) -> Data? {
        guard let list = try? PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any],
              let main = list["WebMainResource"] as? [String: Any], let address = main["WebResourceURL"] as? String
        else { return nil }
        let parts = [main] + (list["WebSubresources"] as? [[String: Any]] ?? [])
        return parts.lazy.filter { $0["WebResourceURL"] as? String == address }
            .compactMap { $0["WebResourceData"] as? Data }
            .first { $0.count <= largest && looksLikePDF($0) }
    }

    static func looksLikePDF(_ data: Data) -> Bool {
        data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }
}

enum ImageText {
    /// The words Vision finds in a picture, a line each, in its reading
    /// order. Blocks: never on the main thread.
    static func lines(in image: Data) -> [String]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(data: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// Off the main thread, and back to it. Nil when Vision couldn't look.
    @MainActor
    static func read(_ image: Data, _ done: @escaping @MainActor ([String]?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = lines(in: image)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(found) } }
        }
    }
}

extension Browser {
    /// Edit › Copy Text from Image/Video: the words in what the page is
    /// showing now, a drawing's or a paused video's included, copied. Your
    /// own action on your own screen; what it reads goes to the clipboard and
    /// nowhere else.
    func copyTextFromPage() {
        guard let tab = active, tab.isWeb, let web = tab.built else { return }
        PageHands.snapshot(web, width: nil) { [weak self] taken in
            guard case .success(let picture) = taken, let png = picture.representation(using: .png, properties: [:]) else {
                self?.announce("Couldn't take a picture of this page")
                return
            }
            ImageText.read(png) { lines in
                guard let lines, !lines.isEmpty else {
                    self?.announce("No text found in what's on screen")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                self?.announce(lines.count == 1 ? "Copied 1 line of text" : "Copied \(lines.count) lines of text")
            }
        }
    }
}
