import CairnProtocol
import Foundation

// cairn: the command line for the Cairn you have open (CairnProtocol/CairnCLI.swift).
// It is in the app, at Cairn.app/Contents/MacOS/cairn; Settings shows the line
// that links it into your PATH.

signal(SIGPIPE, SIG_IGN)
var arguments = Array(CommandLine.arguments.dropFirst())
if let at = arguments.firstIndex(of: "--world"), at + 1 < arguments.count { arguments.removeSubrange(at...(at + 1)) }
let world = CommandLine.arguments.firstIndex(of: "--world").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
var environment = ProcessInfo.processInfo.environment
if let world { environment["SEARCH_PROBE"] = world }
exit(CairnCLI.main(arguments: arguments, environment: environment))
