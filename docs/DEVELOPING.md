# Developing Cairn

Oh, you're *building* it. Look at you. The commands and details below are the straight version, with the occasional interruption from management.

### Why the source is here

Trust issues. Healthy ones.

So anyone can read exactly what a browser handling their passwords and history is doing, build it themselves, or fix something that bothers them. It is about 128,000 lines of Swift in `Sources/Search/`, plus about 73,000 for the optional developer tools and 35,000 of tests, with no dependencies beyond what Apple ships with macOS, one file per concern.

### Building it

Coffee optional. Xcode, regrettably, not.

- macOS 14 or later, Xcode 16 / Swift 6 toolchain
- `swift build` — runs the app straight from the SwiftPM binary
- `./build.sh` — assembles a real, double-clickable `Cairn.app` in `build/`, ad-hoc signed so it runs on your own Mac. An ad-hoc build makes the keychain ask about your saved items again after every rebuild; set `SEARCH_SIGN_IDENTITY` to a free Apple Development certificate's hash and "Always Allow" lasts. `SEARCH_DEV=1 ./build.sh` makes it a dev build, on a yellow icon and named for its branch (`Cairn-split-view` from `claude/split-view-4a6927`), so it's never mistaken for another build; `SEARCH_FEATURE=name` picks the name. It shares the installed app's settings and its bundle id, so while both run, a link from another app may land in either

The names come from `Sources/Search/Brand.swift`; `build.sh` reads that file. What only you know goes in through environment variables, and none has a default that points at anyone else:

| Variable | What it does | Without it |
|---|---|---|
| `CAIRN_BUNDLE_ID` | Builds under another bundle id | `Brand.bundleID` |
| `CAIRN_TEAM_ID` | Your Developer ID team, which signs releases and the feed | nothing is accepted as a release; the on-device AI engine never starts |
| `CAIRN_FEED_URL` | https address of your `appcast.json` | no updater at all |
| `CAIRN_FEEDBACK_ADDRESS` | Where Help › Send Feedback addresses its draft | the draft has no recipient |
| `CAIRN_DOWNLOAD_URL` | The https folder the DMG, ZIP and appcast are served from | `dmg` and `ship` refuse to run |

A build you make yourself won't be notarized, so the first launch needs a right-click → Open (or an allow in System Settings → Privacy & Security). That's expected — it's the same thing that happens with any app that isn't from the App Store or a notarized DMG. `./build.sh release dmg` also makes `Cairn.dmg` / `Cairn.zip` and an appcast; `./build.sh release ship` additionally notarizes and staples, which needs a Developer ID certificate, a provisioning profile for passkeys (`Search.provisionprofile`, git-ignored) and Apple credentials of your own.

`python3 Tests/brand_audit.py` checks that the upstream's name, domain and team id appear nowhere but the licence and credits.

### If you used Search before

It's not a messy breakup. Everyone keeps their own stuff.

Cairn has its own folder, keychain label and bundle id, so it does not see Search's. Nothing is deleted or moved, and nothing is copied without you:

- **Data folder.** The first time Cairn runs without a folder of its own and finds `~/Library/Application Support/Search`, it *copies* it, so pins, history, bookmarks and the session carry over and a Search installed beside this one keeps working.
- **Saved passwords.** They are found without being read, and the Passwords page shows a **Copy to Cairn…** button while there are any. macOS then asks for your login password to let each one go (Always Allow asks once). Search's own items are left exactly as they were.
- **Not carried over:** settings (a different defaults domain), cookies and site sign-ins (WebKit keeps them per app), the proxy password, saved AI keys and the list of coding agents you approved. Enter those again.

### How it's put together

A tour of the guts. Gloves not required.

- **SwiftUI** for everything drawn, **AppKit** for the handful of things SwiftUI doesn't reach on macOS (the window's title bar, dragging the window by an empty part of the tab row), **WKWebView** for pages.
- One `Tab` per page. Its web view is built lazily — a tab restored from last session doesn't cost a process until you switch to it. That's most of why launching with twenty tabs is still instant. Each page runs in WebKit's own content process, as in Safari; a tab you close is really gone.
- The ad blocker is a `WKContentRuleList` compiled once at launch and enforced inside WebKit's networking, before a request is made — zero cost at run time, unlike a JavaScript blocker.
- Hidden elements are a per-site list of selectors injected as a stylesheet at document start, so nothing is ever seen appearing and vanishing.
- Every colour is a light/dark pair in `Design.swift`, resolved by the window's appearance; nothing else in the code knows which mode it is in.
- Extensions run on `WKWebExtension` (macOS 15.4+). `Crx.swift` fetches an extension from the Chrome Web Store's public update address and checks the CRX3 signature against the extension's id before anything is unpacked. `Extensions.swift` is the browser's side of WebKit's contract — tabs, the window, permissions, popups. `ExtensionShims.swift` adds, at install, a small script to the extension's worker, pages and content scripts: it defines the Chrome APIs WebKit lacks — `userScripts`, `privacy`, `browsingData`, `sessions`, the old FileSystem API and more — as calls answered natively by Cairn, and mends the places where WebKit behaves differently from Chrome: replies from pages that don't answer, listeners added after a worker starts, workers WebKit loses track of, members and constants it leaves out. Extension pages are served from `chrome-extension://<id>/`, the address they have in Chrome, so servers and sites recognise them. `./bench ext-*` drives all of it from the shell against a test run. `ExtensionNative.swift` speaks Chrome's native messaging to hosts registered in Chrome's `NativeMessagingHosts` folders.
- `Sources/Search/` is one file per concern: `Vault.swift` is the keychain, `Shield.swift` the ad blocker, `Curtain.swift` the hidden elements, `Session.swift` what comes back at launch, `Updater.swift` the update, `Bench.swift` the test socket, and so on. There's no framework of its own to learn first.

### Testing it without closing it

Because closing forty tabs to run a test is how villains are made.

Turn on **Settings › About › Developer › Let a script drive Cairn** and the running app listens on a Unix socket in its own folder (readable by your user only). `./bench` at the root of the repository speaks it:

```
./bench open https://example.com     # a tab of its own, at the end of your row, marked with a flask
./bench wait 2e7e7e89                 # until it has loaded
./bench text 2e7e7e89                 # the page's text
./bench shot 2e7e7e89 out.png         # a picture of it
./bench click 2e7e7e89 "button.go"    # click, type, submit — through the page's own events
./bench probe                         # the window's state: open panels, a modal, every window
./bench close all
```

Bench tabs are never selected for you, never enter the session or the history, and go when the script says so. It is how this browser is tested while somebody is using it.

For working on the browser itself, `./bench-mcp` is an MCP server over the same test socket. Build first, then register it:

```sh
claude mcp add search-bench -- "$PWD/bench-mcp"
```

Each session starts this checkout's `build/Cairn.app` hidden, in a test world of its own, and wipes that world when it closes; the browser you use is never in reach. `python3 Tests/bench_mcp.py` checks it. This is not the browsing agent above: that is `cairn-mcp` (in the app), whose rules are in `Sources/Search/AgentControl.swift` and `python3 Tests/agent_control.py` and `Tests/agent_gate.py` check them in a hidden probe. [CLAUDE.md](../CLAUDE.md) has the rules for changing any of it.

`python3 Tests/split_view.py`, after `./build.sh`, checks Split View through the app's own model in a hidden test run with its own settings and files, all removed afterwards. It never makes or shows a window; what can only be seen (dragging onto a page's edge, the divider under the pointer, the motion) is checked by hand on a release candidate.

### Keeping up with Search

Once a day, `.github/workflows/upstream-watch.yml` checks Search. If it has commits `main` doesn't, the job opens or updates one draft pull request from `upstream-latest`. It never merges. Do the merge on a branch of your own: resolve clashes, check what is new against the agent rules in [CLAUDE.md](../CLAUDE.md), run the tests, and keep it a merge commit.
