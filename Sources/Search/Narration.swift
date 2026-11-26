import AVFoundation
import AppKit
import MediaPlayer
import SwiftUI
import WebKit

// Listen, in reading mode: the article read aloud a sentence at a time by
// the Mac's own speech (AVSpeechSynthesizer), the sentence marked over the
// page, and the media keys playing, pausing and skipping.
//
// Speech is made on this Mac. The words are the reading page's, found by
// Cairn's script in Cairn's world; the mark is Cairn's own view over the
// page (AgentOverlayView), nothing in it. Better voices are the ones you
// download in System Settings; a Personal Voice is used only once macOS has
// asked you and you pick it.

/// Where a skip lands, by guessed time: speech gives no times ahead of
/// saying them.
enum NarrationPlan {
    /// About what the standard voice says in a second.
    static let lettersPerSecond = 14.0

    static func seconds(_ length: Int) -> Double { max(Double(length) / lettersPerSecond, 0.5) }

    /// The sentence `by` seconds from the start of sentence `from`, forward
    /// or back. Always at least one sentence along, and inside the article.
    static func target(from: Int, by: Double, lengths: [Int]) -> Int {
        guard !lengths.isEmpty else { return 0 }
        var at = min(max(from, 0), lengths.count - 1)
        var left = abs(by)
        while left > 0 {
            if by > 0 {
                guard at < lengths.count - 1 else { break }
                left -= seconds(lengths[at])
                at += 1
            } else {
                guard at > 0 else { break }
                at -= 1
                left -= seconds(lengths[at])
            }
        }
        return at
    }

    static func elapsed(at index: Int, lengths: [Int]) -> Double {
        lengths.prefix(max(index, 0)).reduce(0) { $0 + seconds($1) }
    }
}

extension PageScripts {
    /// The reading page's sentences, in order, each remembered as a range
    /// for `sentence`. Code is left out: read aloud it is noise.
    static func sentences() -> String {
        call(#"""
        (function () {
          var root = document.getElementById('office-reader'), kept = [], said = [];
          globalThis.__cairnSpeech = kept;
          if (!root) return JSON.stringify({ sentences: said, lang: '' });
          var BLOCK = 'h1,h2,h3,h4,h5,h6,p,li,blockquote,figcaption,td,th,dt,dd,summary';
          var split = window.Intl && Intl.Segmenter ? new Intl.Segmenter(document.documentElement.lang || undefined, { granularity: 'sentence' }) : null;
          function parts(text) {
            if (split) return Array.from(split.segment(text), function (s) { return [s.index, s.segment]; });
            var out = [], found, any = /[^.!?]+[.!?]*\s*/g;
            while ((found = any.exec(text))) out.push([found.index, found[0]]);
            return out;
          }
          var blocks = new Map(), order = [];
          var walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          for (var n = walk.nextNode(); n; n = walk.nextNode()) {
            var el = n.parentElement;
            if (!el || el.closest('pre,.office-from,script,style') || !visible(el)) continue;
            var block = el.closest(BLOCK) || el;
            if (!blocks.has(block)) { blocks.set(block, []); order.push(block); }
            blocks.get(block).push(n);
          }
          order.forEach(function (block) {
            var nodes = blocks.get(block), text = nodes.map(function (n) { return n.nodeValue; }).join('');
            function point(at) {
              var passed = 0;
              for (var i = 0; i < nodes.length; i++) {
                var long = nodes[i].nodeValue.length;
                if (at <= passed + long) return [nodes[i], at - passed];
                passed += long;
              }
              return [nodes[nodes.length - 1], nodes[nodes.length - 1].nodeValue.length];
            }
            parts(text).forEach(function (p) {
              var words = p[1].replace(/\s+/g, ' ').trim();
              if (!/[\p{L}\p{N}]/u.test(words) || kept.length >= 4000) return;
              var lead = p[1].length - p[1].replace(/^\s+/, '').length;
              var range = document.createRange(), from = point(p[0] + lead), to = point(p[0] + p[1].replace(/\s+$/, '').length);
              range.setStart(from[0], from[1]);
              range.setEnd(to[0], to[1]);
              kept.push(range);
              said.push(words.slice(0, 1000));
            });
          });
          return JSON.stringify({ sentences: said, lang: document.documentElement.lang || '' });
        })
        """#, [])
    }

    /// Where sentence `index` is now; brought into view when `show`. Gone
    /// with the reading page.
    static func sentence(_ index: Int, show: Bool) -> String {
        call(#"""
        (function (i, show) {
          var range = (globalThis.__cairnSpeech || [])[i];
          if (!range || !range.startContainer.isConnected || !document.getElementById('office-reader'))
            return JSON.stringify({ gone: true });
          var r = range.getBoundingClientRect();
          if (show && (r.top < 40 || r.bottom > innerHeight - 60)) {
            scrollBy(0, r.top - innerHeight / 3);
            r = range.getBoundingClientRect();
          }
          return JSON.stringify({ box: [r.left, r.top, r.width, r.height] });
        })
        """#, [index, show])
    }
}

@MainActor
final class Narrator: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Narrator()
    static let voiceKey = "reader.voice"

    enum State: Equatable { case idle, playing, paused }

    @Published private(set) var state: State = .idle
    /// The tab being read, one at a time.
    @Published private(set) var reading: Tab.ID?

    private var synthesizer: AVSpeechSynthesizer?
    private weak var tab: Tab?
    private var sentences: [String] = []
    private var language = ""
    private var index = 0
    /// The utterance in hand: one let go says nothing that counts.
    private var current: AVSpeechUtterance?
    private var follower: Timer?
    private var marked: CGRect?
    private var commands: [(MPRemoteCommand, Any)] = []

    // MARK: - controls

    func start(_ tab: Tab) {
        stop()
        guard tab.reader, let web = tab.built else { return }
        self.tab = tab
        reading = tab.id
        web.evaluateJavaScript(PageScripts.sentences(), in: nil, in: Web.world) { [weak self, weak tab] result in
            guard let self, let tab, reading == tab.id, state == .idle else { return }
            let out = Self.object(try? result.get())
            let found = out?["sentences"] as? [String] ?? []
            guard !found.isEmpty else { return stop() }
            sentences = found
            language = out?["lang"] as? String ?? ""
            let synthesizer = AVSpeechSynthesizer()
            synthesizer.delegate = self
            self.synthesizer = synthesizer
            takeKeys()
            say(0)
            follow()
        }
    }

    func playPause() {
        guard let synthesizer else { return }
        switch state {
        case .playing:
            synthesizer.pauseSpeaking(at: .immediate)
            state = .paused
        case .paused:
            state = .playing
            if !synthesizer.continueSpeaking() { say(index) }
        case .idle:
            return
        }
        tellNowPlaying()
    }

    /// Forward or back by about so many seconds.
    func skip(_ seconds: Double) {
        guard synthesizer != nil else { return }
        say(NarrationPlan.target(from: index, by: seconds, lengths: sentences.map(\.count)))
    }

    func stop() {
        follower?.invalidate()
        follower = nil
        current = nil
        synthesizer?.delegate = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        if let web = tab?.built, marked != nil { AgentOverlayView.over(web).clear() }
        marked = nil
        tab = nil
        sentences = []
        index = 0
        if !commands.isEmpty {
            for (command, token) in commands { command.removeTarget(token) }
            commands = []
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
        state = .idle
        reading = nil
    }

    // MARK: - speaking

    private func say(_ at: Int) {
        guard let synthesizer, sentences.indices.contains(at) else { return stop() }
        index = at
        current = nil
        if synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: sentences[at])
        utterance.voice = Self.voice(for: language)
        current = utterance
        state = .playing
        synthesizer.speak(utterance)
        mark(show: true)
        tellNowPlaying()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let done = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let current, ObjectIdentifier(current) == done else { return }
            if index + 1 < sentences.count { say(index + 1) } else { stop() }
        }
    }

    /// The voice you picked, if it is still there and speaks the page's
    /// language; else the best one on this Mac that does.
    static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let wanted = language.isEmpty ? AVSpeechSynthesisVoice.currentLanguageCode() : language
        let tongue = wanted.prefix { $0 != "-" && $0 != "_" }.lowercased()
        if let id = Store.settings.string(forKey: voiceKey), let picked = AVSpeechSynthesisVoice(identifier: id),
           picked.language.lowercased().hasPrefix(tongue) {
            return picked
        }
        let best = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(tongue) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        // Nothing better than the standard ones: the system's own choice.
        if let best, best.quality != .default { return best }
        return AVSpeechSynthesisVoice(language: wanted)
    }

    /// The voices worth offering: the downloaded better ones, and your own
    /// once macOS has let them be used.
    static func offered() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.quality != .default || $0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    // MARK: - the mark

    /// The page moves under a mark drawn over it: where the sentence is, is
    /// asked again a few times a second. Also how the end of reading mode is
    /// noticed.
    private func follow() {
        follower = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.mark(show: false) }
        }
    }

    private func mark(show: Bool) {
        guard let tab, tab.reader, !tab.asleep, let web = tab.built,
              Browsers.all.contains(where: { browser in browser.tabs.contains { $0 === tab } }) else { return stop() }
        let asked = index
        web.evaluateJavaScript(PageScripts.sentence(asked, show: show), in: nil, in: Web.world) { [weak self, weak web] result in
            guard let self, let web, asked == index, synthesizer != nil else { return }
            let out = Self.object(try? result.get())
            if out?["gone"] as? Bool == true || out == nil { return stop() }
            guard let box = out?["box"] as? [Double],
                  let place = AgentOverlayView.place(box, zoom: web.pageZoom * web.magnification),
                  place != marked else { return }
            marked = place
            let overlay = AgentOverlayView.over(web)
            overlay.clear()
            overlay.show("Listening", at: place, spotlight: true)
        }
    }

    private static func object(_ value: Any?) -> [String: Any]? {
        (value as? String)?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    // MARK: - the media keys

    private func takeKeys() {
        let center = MPRemoteCommandCenter.shared()
        func take(_ command: MPRemoteCommand, _ act: @escaping @MainActor (Narrator) -> Void) {
            command.isEnabled = true
            let token = command.addTarget { [weak self] _ in
                Task { @MainActor in if let self { act(self) } }
                return .success
            }
            commands.append((command, token))
        }
        take(center.togglePlayPauseCommand) { $0.playPause() }
        take(center.playCommand) { if $0.state == .paused { $0.playPause() } }
        take(center.pauseCommand) { if $0.state == .playing { $0.playPause() } }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        take(center.skipForwardCommand) { $0.skip(15) }
        take(center.skipBackwardCommand) { $0.skip(-15) }
    }

    private func tellNowPlaying() {
        guard !commands.isEmpty else { return }
        let lengths = sentences.map(\.count)
        // Control Centre is seen by whoever is at the Mac: a private tab's
        // article isn't named there.
        let title = tab.map { $0.shy ? "Reading aloud" : $0.title } ?? ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: Brand.name,
            MPMediaItemPropertyPlaybackDuration: NarrationPlan.elapsed(at: lengths.count, lengths: lengths),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: NarrationPlan.elapsed(at: index, lengths: lengths),
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = state == .playing ? .playing : .paused
    }
}

/// Listen, in the article's corner.
struct ListenControl: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var narrator = Narrator.shared
    @State private var hovering = false

    private var mine: Bool { narrator.reading == tab.id && narrator.state != .idle }

    var body: some View {
        HStack(spacing: 2) {
            if mine {
                button("gobackward.15", "Back 15 Seconds") { narrator.skip(-15) }
                button(narrator.state == .playing ? "pause.fill" : "play.fill",
                       narrator.state == .playing ? "Pause" : "Play") { narrator.playPause() }
                button("goforward.15", "Forward 15 Seconds") { narrator.skip(15) }
                button("stop.fill", "Stop Listening") { narrator.stop() }
            } else {
                Button { narrator.start(tab) } label: {
                    Label("Listen", systemImage: "speaker.wave.2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Read this article aloud")
            }
            voices
        }
        .padding(3)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .opacity(hovering || mine ? 1 : 0.55)
        .onHover { hovering = $0 }
    }

    private var voices: some View {
        Menu {
            Button("Automatic") { Store.settings.removeObject(forKey: Narrator.voiceKey) }
            ForEach(Narrator.offered(), id: \.identifier) { voice in
                Button("\(voice.name) (\(voice.language))") {
                    Store.settings.set(voice.identifier, forKey: Narrator.voiceKey)
                }
            }
            Divider()
            if AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .notDetermined {
                // macOS puts its own question; nothing is used until then.
                Button("Allow Personal Voice…") {
                    AVSpeechSynthesizer.requestPersonalVoiceAuthorization { _ in }
                }
            }
            Text("More voices: System Settings › Accessibility › Spoken Content")
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20, height: 22)
        .help("Voice")
        .accessibilityLabel("Voice")
    }

    private func button(_ symbol: String, _ name: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 24, height: 22)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }
}
