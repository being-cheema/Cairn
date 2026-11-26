import CairnProtocol
import Foundation

// cairn-mcp: the MCP server a coding agent runs to use the Cairn you have
// open (CairnProtocol/MCPServer.swift). It is in the app, at
// Cairn.app/Contents/MacOS/cairn-mcp:
//
//     claude mcp add cairn -- /path/to/Cairn.app/Contents/MacOS/cairn-mcp
//
//     cairn-mcp --world NAME    a test world's Cairn (SEARCH_PROBE=NAME)

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment
let world = arguments.firstIndex(of: "--world").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    ?? environment["SEARCH_PROBE"]
// The side panel's pass for this run, if Cairn started it: taken out of the
// environment, so nothing this starts inherits it.
let pass = environment[AgentWire.passVariable] ?? ""
unsetenv(AgentWire.passVariable)
// A client that stops reading must not end this with a signal.
signal(SIGPIPE, SIG_IGN)

MCPServer(socket: AgentWire.socket(world: world, home: environment["HOME"] ?? NSHomeDirectory()), pass: pass).run()
