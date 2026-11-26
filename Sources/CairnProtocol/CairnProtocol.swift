import Foundation

// What the browser and the MCP server an agent runs (cairn-mcp) say to each
// other, written once and compiled into both: the verbs, where the socket is,
// how a socket is checked, and the tools with the verb each one sends.
//
// The wire is one JSON object per line: {"do": verb, "n": number, …} to the
// browser, its answer with the same number back, and {"error": {code,
// message, hint}} for a refusal. The first line is a "hello" with the
// agent's name, and the side panel's pass when there is one.

/// Everything the browser will do for an agent. The browser's switch over
/// these is exhaustive, and each tool names one, so a verb can't be added on
/// one side alone.
public enum AgentVerb: String, CaseIterable, Sendable {
    case hello, status, tabs, open, go, back, forward, close, read, click, type, press, scroll
    case waitFor = "wait_for"
    case waitForSignIn = "wait_for_sign_in"
    case shot, bye
    case createArtifact = "create_artifact"
    case batchRead = "batch_read"
}

public enum AgentWire {
    /// Where the side panel's pass for a run is handed to cairn-mcp: its
    /// environment, which other programs can't list as they can arguments.
    public static let passVariable = "CAIRN_PANEL_PASS"
    /// The browser's folder in Application Support (Brand.folderName; a test
    /// holds the two together).
    public static let folderName = "Cairn"

    /// The browser's socket, in a test world's folder when `world` names one,
    /// as Store.world makes the name.
    public static func socket(world: String?, home: String) -> String {
        var folder = folderName
        if let world, !world.isEmpty {
            let kept = world.lowercased().filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
            folder += " (\(kept.isEmpty || kept == "1" ? "test" : kept))"
        }
        return "\(home)/Library/Application Support/\(folder)/Agent/agent.sock"
    }

    /// The socket and its folder are this user's and nothing else's: a
    /// socket, not a link, in a folder only this user can open. Anything else
    /// could be some other program standing in for the browser.
    public static func isThisUsers(socket path: String) -> Bool {
        var sock = stat(), room = stat()
        guard lstat(path, &sock) == 0, lstat((path as NSString).deletingLastPathComponent, &room) == 0 else { return false }
        return sock.st_mode & S_IFMT == S_IFSOCK && sock.st_uid == getuid()
            && room.st_mode & S_IFMT == S_IFDIR && room.st_uid == getuid() && room.st_mode & 0o077 == 0
    }
}
