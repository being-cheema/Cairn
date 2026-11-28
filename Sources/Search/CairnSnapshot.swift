import CryptoKit
import Foundation
import WebKit

// A .cairnsnapshot: one page, kept by you, to read again offline.
//
// File › Save Page as Cairn Snapshot… writes a folder in Application
// Support/Cairn/Archives: the page as WebKit's own web archive (it opens
// again in Cairn or Safari with no network), the page's words and controls
// as the agent reading it saw them (JSON), and a manifest with what and when
// and a hash of each part, so an edited snapshot is noticed. Only when you
// ask, only for the tab in front, never a private tab, and what you typed
// into a box is in neither part: the controls' values are left out and a
// card number or key in the text is hidden as it is for a model. Nothing
// here reads, sends or loads anything by itself; you can delete one in
// Finder or with Delete All Snapshots.

enum CairnSnapshots {
    static let ending = "cairnsnapshot"
    static var folder: URL { Store.file("Archives") }

    struct Manifest: Codable, Equatable {
        var format = 1
        var title: String
        var url: String
        var savedAt: Date
        var archiveHash: String
        var extractedHash: String
        var note = "Saved by you from a tab you were looking at. Values typed into boxes are not in it."
    }

    struct Entry: Equatable, Identifiable {
        var id: URL { bundle }
        let bundle: URL
        let manifest: Manifest
        /// The two parts are as they were saved.
        let intact: Bool
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The page's reading, as stored: addresses without their values, no
    /// control's value at all, secrets hidden in the words.
    static func extracted(from read: [String: Any], archetype: [String: Any]?, title: String, url: String) -> [String: Any] {
        var out: [String: Any] = ["url": AgentRules.url(url), "title": title]
        out["text"] = TypedSecrets.hidden(in: read["text"] as? String ?? "")
        out["nodes"] = (read["nodes"] as? [[String: Any]] ?? []).map { node -> [String: Any] in
            var node = node
            for key in ["value", "e", "box", "inView", "filled"] { node.removeValue(forKey: key) }
            if let href = node["href"] as? String { node["href"] = AgentRules.url(href) }
            return node
        }
        if let archetype { out["archetype"] = archetype }
        if let structured = read["structured"] { out["structured"] = structured }
        out["saved_by"] = "Cairn snapshot, format 1"
        return out
    }

    private static func name(_ title: String, at date: Date) -> String {
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateSeparator(.omitted).timeSeparator(.omitted))
        return "\(SkillRecording.slug(title, fallback: "page"))-\(stamp).\(ending)"
    }

    /// Written as a folder only you can open. Nil when it can't be.
    @discardableResult
    static func write(archive: Data, extracted: [String: Any], title: String, url: String,
                      in folder: URL = CairnSnapshots.folder, now: Date = Date()) -> URL? {
        guard JSONSerialization.isValidJSONObject(extracted),
              let json = try? JSONSerialization.data(withJSONObject: extracted, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        let manifest = Manifest(title: String(title.prefix(200)), url: AgentRules.url(url), savedAt: now,
                                archiveHash: hash(archive), extractedHash: hash(json))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let described = try? encoder.encode(manifest) else { return nil }
        let files = FileManager.default
        let bundle = folder.appendingPathComponent(name(title, at: now), isDirectory: true)
        do {
            try files.createDirectory(at: bundle, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (file, data) in [("page.webarchive", archive), ("extracted.json", json), ("manifest.json", described)] {
                let at = bundle.appendingPathComponent(file)
                try data.write(to: at, options: [.atomic])
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: at.path)
            }
            return bundle
        } catch {
            try? files.removeItem(at: bundle)
            return nil
        }
    }

    static func list(in folder: URL = CairnSnapshots.folder) -> [Entry] {
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return found.filter { $0.pathExtension == ending }.compactMap { bundle in
            guard let described = try? Data(contentsOf: bundle.appendingPathComponent("manifest.json")),
                  let manifest = try? decoder.decode(Manifest.self, from: described) else { return nil }
            let archive = try? Data(contentsOf: bundle.appendingPathComponent("page.webarchive"))
            let read = try? Data(contentsOf: bundle.appendingPathComponent("extracted.json"))
            let intact = archive.map(hash) == manifest.archiveHash && read.map(hash) == manifest.extractedHash
            return Entry(bundle: bundle, manifest: manifest, intact: intact)
        }.sorted { $0.manifest.savedAt > $1.manifest.savedAt }
    }

    /// Only a snapshot folder, by its ending, and not a link to something else.
    @discardableResult
    static func delete(_ bundle: URL) -> Bool {
        guard bundle.pathExtension == ending,
              (try? bundle.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return false }
        return (try? FileManager.default.removeItem(at: bundle)) != nil
    }

    static func deleteAll(in folder: URL = CairnSnapshots.folder) {
        for entry in list(in: folder) { delete(entry.bundle) }
    }
}

extension Browser {
    /// File › Save Page as Cairn Snapshot…: your own save of the page in front.
    func saveSnapshot() {
        guard let tab = active, tab.isWeb, !tab.shy, let web = tab.built,
              let address = tab.pageAddress, ["http", "https"].contains(address.scheme?.lowercased() ?? "") else {
            return announce("A snapshot is of a web page in a normal tab, never a private one")
        }
        let title = tab.title
        web.createWebArchiveData { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, case .success(let archive) = result else { return self?.announce("Couldn't save a snapshot") ?? () }
                let key = "__cairnSnapshot"
                web.evaluateJavaScript(PageScripts.read(key: key, snap: 1, most: 600, longest: 200_000, text: true, structured: true),
                                       in: nil, in: Web.world) { read in
                    MainActor.assumeIsolated {
                        guard case .success(let value) = read, let text = value as? String,
                              let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                            return self.announce("Couldn't save a snapshot")
                        }
                        web.evaluateJavaScript(PageScripts.archetype(), in: nil, in: Web.world) { kind in
                            MainActor.assumeIsolated {
                                var found: [String: Any]?
                                if case .success(let value) = kind, let said = value as? String,
                                   let object = try? JSONSerialization.jsonObject(with: Data(said.utf8)) as? [String: Any] {
                                    found = object["archetype"] as? [String: Any]
                                }
                                let kept = CairnSnapshots.extracted(from: parsed, archetype: found, title: title, url: address.absoluteString)
                                if CairnSnapshots.write(archive: archive, extracted: kept, title: title, url: address.absoluteString) != nil {
                                    self.announce("Saved a snapshot of this page")
                                } else {
                                    self.announce("Couldn't save a snapshot")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func showSnapshots() {
        try? FileManager.default.createDirectory(at: CairnSnapshots.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(CairnSnapshots.folder)
    }

    /// Asks first: a deleted snapshot can't come back.
    func deleteAllSnapshots() {
        let count = CairnSnapshots.list().count
        guard count > 0 else { return announce("No snapshots to delete") }
        let alert = NSAlert()
        alert.messageText = "Delete \(count) snapshot\(count == 1 ? "" : "s")?"
        alert.informativeText = "They are removed from this Mac and can't be brought back."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        CairnSnapshots.deleteAll()
        announce("Deleted the snapshots")
    }
}
