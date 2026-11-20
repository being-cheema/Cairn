import Foundation

// What this fork is called, in one place.
//
// Cairn is a fork of Search (MIT, by Office Commun, credited in About and the
// README). The upstream asks forks to rename and not to reuse "Search" or its
// icon, and a fork that kept the upstream's identifiers would also have kept
// its update feed: every copy would have gone on asking the upstream's server
// for a build signed by the upstream's key. So nothing outside this file, and
// the build script that reads it, spells a name, an identifier or an address:
// Tests/brand_audit.py fails the build of the tests if one comes back.
//
// What is *not* here on purpose: a feed and a signing team. They belong to
// whoever builds and publishes, not to the source. build.sh writes them into
// Info.plist from CAIRN_FEED_URL and CAIRN_TEAM_ID, and without them the
// updater does nothing at all — no timer, no request (Updater.feed).

enum Brand {
    /// What people see: the menu bar, About, dialogs.
    static let name = "Cairn"

    /// The bundle id, and so the defaults domain, the WebKit container and
    /// every keychain service below. build.sh reads this line for its own
    /// default, so CAIRN_BUNDLE_ID is only needed to build a copy under
    /// another id; change it here and nothing else has to follow.
    static let bundleID = "io.github.being-cheema.cairn"

    /// Under ~/Library/Application Support.
    static let folderName = "Cairn"

    /// What every password item of ours is tagged with in the keychain
    /// (Vault). A test run adds its world in brackets.
    static let keychainLabel = "Cairn"

    /// The names the upstream's data lives under, read only when this app has
    /// none of its own yet: the folder is copied (never moved, so a Search
    /// installed beside this keeps working) and saved passwords are offered
    /// for copying (Vault.legacy).
    static let legacyFolderName = "Search"
    static let legacyKeychainLabel = "Search"

    /// Log subsystem and the prefix of every service name.
    static var logSubsystem: String { bundleID }
    static func service(_ part: String) -> String { "\(bundleID).\(part)" }

    /// The AI add-on's engine, and the identifier its signature must carry.
    static var engineIdentifier: String { service("ai-engine") }

    /// The identifier the signed feed carries (build.sh signs it as this).
    static var feedIdentifier: String { service("appcast") }

    /// Where the signed update feed is, if the person who built this copy
    /// gave one (build.sh: CAIRN_FEED_URL). Nil means no updater.
    static var feedURL: URL? {
        guard let text = info("CairnFeedURL"), let url = URL(string: text),
              url.scheme?.lowercased() == "https", url.host != nil
        else { return nil }
        return url
    }

    /// The Apple team whose Developer ID signs releases and the feed
    /// (build.sh: CAIRN_TEAM_ID). Nil means nothing can be verified as a
    /// release, so nothing is: no update is taken, no engine is started.
    static var teamID: String? {
        guard let text = info("CairnTeamID"), text.count == 10,
              text.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) })
        else { return nil }
        return text
    }

    /// Where Help › Send Feedback addresses its draft (build.sh:
    /// CAIRN_FEEDBACK_ADDRESS). Nil: the draft has no recipient.
    static var feedbackAddress: String? { info("CairnFeedbackAddress") }

    /// OpenRouter's sign-in sends the tab back to an address of ours, which
    /// is never loaded: the browser takes it as the tab is about to go there
    /// (AISignIn). `.invalid` is reserved never to resolve, so if it ever
    /// were loaded it would reach nobody.
    static let callbackHost = "cairn.invalid"

    private static func info(_ key: String) -> String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}
