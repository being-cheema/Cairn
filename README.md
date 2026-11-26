# Cairn

*A browser made by Claude, for Claude.* Claude does the work in tabs of its
own, and you approve anything that matters.

A small, quiet web browser for the Mac, built on WebKit, and a personal fork of
[Search](https://github.com/driceroland/Search) by [Office Commun](https://officecommun.com),
which is MIT-licensed. The browser it started from is theirs. Where this README
says "upstream", it means Search.

**macOS 14 or later** (extensions need 15.4). There is no download: build it
yourself (see [Building it](#building-it)). Nothing here is notarised or
published for anyone else.

## What this fork adds

- **Claude in the side panel** (`⌥⌘K`), run by the Claude Code program already
  on your Mac, to browse for you in tabs of its own.
- **The same door for your own agents**, such as Claude Code in a terminal.
- **Its own passwords, verification codes and passkeys**, kept on this Mac.
- Its own name, look and data folder, with everything that talked to the
  upstream's servers cut off.

## Claude, and what it can't do

**The panel.** Cairn starts your installed `claude`, and only a copy Anthropic
signed. It gets no tools but this browser's: no shell, no files, no web search.
Cairn has no Claude sign-in of its own; it uses whatever your Claude Code is
signed in to. Nothing to switch on: pressing Send is the go-ahead.

**Your own agent.** Register the MCP server that is inside the app (run this
from the repository, after building):

```bash
claude mcp add search -- "$PWD/build/Cairn.app/Contents/MacOS/cairn-mcp"
```

Cairn asks you in the window when it connects. "Always allow" is offered only
by a build signed with a provisioning profile.

**The rules, for both:**

| | |
|---|---|
| Its tabs | Opened by it, in a store of their own: signed in to nothing, none of your cookies. It can't drive your tabs and never sees private ones. It can read your open tabs only if you tick that box for an outside agent. |
| Secrets | It never gets, types or fills a saved password, passkey, card number or one-time code. Those fields are blanked in what it reads and in screenshots. It can't sign in. |
| Your click | Paying, sending, signing in, submitting a form and going to a site the task hasn't used wait for **Approve**. Only a real click of yours answers. |
| Forms | A form is held again as it leaves the page, whatever its button said and in any language, unless your Approve just covered it. |
| Your network | It can't reach this Mac, your local network or other private addresses, including through redirects. That means it can't test a site on `localhost` yet. |
| Stop | Closes its tabs. A task that finishes normally leaves them to you. |

**The limits of those rules.** What a page's script sends with `fetch` or XHR
isn't a page load, so the browser can't hold it: a button that sends that way
is held only if its wording or its form gives it away, and the wording checks
are English. The private-network block looks a name up before WebKit does, so
a server that changes its answer in between (DNS rebinding) can get past it,
and a public name pointing inside can still be fetched by a page's own script.
Treat the approval card as a strong guard, not a proof. Claude can be wrong,
and a page can try to talk it into things.

**Playbooks.** Type `/` at the start of the panel's box for `/compare-tabs`,
`/audit-a11y`, `/extract-data`, `/repro-check` and your own: Markdown files in
`~/Library/Application Support/Cairn/Skills/`, with `name`, `description` and
`argument_hint` frontmatter. A playbook is words added to your message when you
press Send. It gives Claude no new tool or permission.

**Not in this build:** the upstream's summarise-and-ask AI add-on is in the
source but switched off (`AI.shipped`).

---

## What it is

Cairn is a browser with nothing in the way. A row of tabs — down the left, or across the top if you prefer — and the page. There is no toolbar, no start page, no sidebar of suggestions, no account to sign into, nothing that wants your attention. You type an address or a few words in one field and you are on the page.

It uses **WebKit**, the engine already inside every Mac (it is what Safari runs on). That is why the whole app is under 20 MB on disk and opens quickly: there is no second copy of Chromium to download, update and keep in memory.

The upstream was built by a design studio that spends its whole day in a browser and was tired of the ones that had become products. This one is a tool too.

## What it does

- **One field.** Type an address and you go there; type words and you search. It finishes addresses from your own history and never sends what you type anywhere until you press Return.
- **Tabs that stay out of the way.** Pin the pages you keep open all day and they shrink to a letter or their icon. Tabs from your last session come back instantly and cost nothing until you click them. `⌘K` lists your open tabs by name.
- **Keep an important site running.** Enable Keep selected sites awake in Settings › Tabs, then choose Keep This Site Awake in the site card. It prevents sleeping and automatic closure, even under memory pressure, at the cost of more memory. Private choices last only in that tab; manual closing still works.
- **Two pages side by side.** Turn on Split View in Settings › Tabs, then drag a tab onto a page or choose Tabs › Split Current Page. Drag the divider to resize the panes; the outlined pane receives page commands. Pairs and their widths come back with their Space, including after a restart.
- **Reading mode.** `⇧⌘R` strips a page down to the article.
- **Hide anything, for good.** `⇧⌘H`, then click a cookie banner, a newsletter overlay, a rail of "related" nonsense — it goes, and it is still gone on that site next time, before the page has drawn a single frame.
- **An ad blocker that runs before the page.** Third-party trackers and ad networks are stopped at the network level, so there is nothing to render and nothing to slow down. On by default, off per site if something breaks.
- **Video that follows you.** `⇧⌘P` lifts the video out of the page into a small window that stays above everything, including other apps.
- **Passwords, in your keychain.** Cairn offers to save a sign-in once it has worked, and lists your accounts under the field when you click it. It never fills anything on its own. The Passwords page (`⌥⌘L`) has verification codes (TOTP), a strong-password generator, a health check done on this Mac (reused, weak, old, plain http), import from other browsers and managers, and export as an encrypted backup or a plain CSV.
- **Passkeys of its own.** Without Apple's browser entitlement, which needs a paid developer account, Cairn makes and keeps passkeys itself, behind Touch ID. They are not your iCloud Keychain passkeys: sign in another way once, then add a Cairn passkey in the site's settings. Passkeys made here stay on this Mac. There is no phone or security-key sign-in this way. Importing from Apple's Passwords app is written but has never worked on a real export.
- **Light, dark, or the Mac's own.** The frame and the pages follow.
- **A wall behind the blank tab, if you like.** Settings › Themes paints it with a scenic mural, a pack of stickers, a colour, a gradient or a picture of your own, in light and dark, drawn once and kept so it costs nothing while you browse. Off until you choose one.
- **Bookmarks, history, downloads** — each a panel, each searchable, each one keystroke away.
- **Chrome extensions, without Chrome.** Paste a Chrome Web Store link in Settings › Extensions, or open the extension's page in Cairn and press Add. It runs on WebKit's own extension engine — the one Safari uses — and where Chrome has APIs WebKit doesn't (bookmarks, history, downloads, side panel, offscreen documents, fonts, notifications, speech, OAuth sign-in), Cairn fills them in itself. They live behind the puzzle button; pin the ones you use often. Building your own? Load its folder as an unpacked extension and press Reload after each change, as in Chrome's developer mode. macOS 15.4 or later.
- **Updates only if you give it somewhere to look.** A build made without an update feed (the default) has no updater: no timer, no request, no menu item. If you build one with `CAIRN_FEED_URL` and `CAIRN_TEAM_ID`, it checks that feed at launch and then every hour, downloads a newer build, verifies it is signed by your team, and swaps it in for the next launch. Nothing restarts on its own.

## What it doesn't do

On purpose:

- No extension you have to install to feel at home. Blocking ads, hiding clutter, reading mode, picture-in-picture and passwords are built in; extensions are there for everything else.
- No account, no cloud, no server of ours. Sync is **opt-in** and off by default: turn it on in Settings › General and pick a folder (iCloud Drive, Dropbox, a shared disk); it writes small files there and whatever moves that folder between your Macs does the rest. Without it, your tabs, history and passwords are on your Mac and nowhere else.
- No telemetry, no analytics, no crash reports sent anywhere. What leaves your Mac is what you use: the pages you ask for and their icons, search suggestions if you turn them on, the Chrome Web Store for extensions you add, live folders you set up, what your Claude Code sends when you use Claude, and, only if you built it with a feed, one small hourly request for the update file.
- Several windows are supported (⌘N), each with tabs of its own; pinned tabs are shared.

## Privacy, concretely

| What | Where it is | Who can read it |
|---|---|---|
| Passwords, codes, passkeys | The macOS login keychain, as items tagged `Cairn` | Cairn, as you signed it. Another app gets the system's permission dialog. Touch ID is asked by Cairn itself, not enforced by the keychain. |
| History, bookmarks, open tabs, hidden elements | Small files in `~/Library/Application Support/Cairn/` | You. |
| Cookies and site data | WebKit's own store for the app | The sites that set them. |
| Extensions | `~/Library/Application Support/Cairn/Extensions/`, their data in WebKit's extension store | Each extension, within the permissions you accepted. |
| Folder sync, if you turn it on | A `Cairn Sync` folder inside the folder you pick | Whoever can read that folder. |
| What you ask Claude, and what it reads for you | Sent to Anthropic by your own Claude Code | Anthropic, under your account's terms. Nothing goes until you press Send or your agent asks. Cairn doesn't save Claude's replies. |
| A record of each side-panel task: what you typed, the model, the sites, how approvals were answered, and the titles and addresses of tabs left to you | Files in `~/Library/Application Support/Cairn/Tasks/`, readable by your account alone, at most 200 | You. Delete them in the panel's Task History. Clearing all history deletes them too. |
| Anything else | Nowhere. This project has no server. | — |

A **private tab** (`⇧⌘N`) has its own cookie jar and leaves nothing behind when it closes.

Apps you allow in System Settings › Privacy & Security › Automation can read the address and title of your tabs with AppleScript, and the name of the space and profile each window is in; private tabs are never shown, and a window with one in front shows neither name.

## Keyboard

| | |
|---|---|
| `⌘L` address · `⌘K` switch tab · `⌘T` new tab · `⌘W` close · `⇧⌘T` reopen | `⌘[` `⌘]` back, forward · `⇧⌘[` `⇧⌘]` previous, next tab · `⌘1`–`⌘9` jump |
| `⇧⌘S` tabs down the left or across the top · `⌘S` fold the sidebar away · `⇧⌘B` bookmark this page | `⇧⌘R` reading mode · `⇧⌘P` float the video · `⇧⌘H` hide something · `⇧⌘U` what is hidden here |
| `⌘F` find · `⌘D` duplicate tab · `⇧⌘C` copy address · `⇧⌘V` paste and go | `⌘Y` history · `⇧⌘J` downloads · `⌘,` settings · `⌥⌘L` passwords |

Space keys (Control+1–9 by default) and the modifier used to peek at a link can be changed in Settings › Shortcuts while those features are enabled.

`⌘R` reloads the page; `⌥⌘R` reloads it from origin, checking everything cached with the site again, as Safari's Reload Page From Origin, which is also in a right-click on the reload button.

`⌃Tab` and `⌃⇧Tab` walk along the row of tabs; `Tab` stays the page's, for moving through a form. `esc` puts away whatever is open.

With Split View on, `⌥⌘N` splits the current page and `⌃⌘←` / `⌃⌘→` go from one page to the other. `⌘W` closes the focused tab and gives the remaining page the whole area. Tabs › Separate Split Tabs keeps both tabs open separately.

---

## For developers

### Why the source is here

So anyone can read exactly what a browser handling their passwords and history is doing, build it themselves, or fix something that bothers them. It is about 128,000 lines of Swift in `Sources/Search/`, plus about 73,000 for the optional developer tools and 35,000 of tests, with no dependencies beyond what Apple ships with macOS, one file per concern.

### Building it

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

Cairn has its own folder, keychain label and bundle id, so it does not see Search's. Nothing is deleted or moved, and nothing is copied without you:

- **Data folder.** The first time Cairn runs without a folder of its own and finds `~/Library/Application Support/Search`, it *copies* it, so pins, history, bookmarks and the session carry over and a Search installed beside this one keeps working.
- **Saved passwords.** They are found without being read, and the Passwords page shows a **Copy to Cairn…** button while there are any. macOS then asks for your login password to let each one go (Always Allow asks once). Search's own items are left exactly as they were.
- **Not carried over:** settings (a different defaults domain), cookies and site sign-ins (WebKit keeps them per app), the proxy password, saved AI keys and the list of coding agents you approved. Enter those again.

### How it's put together

- **SwiftUI** for everything drawn, **AppKit** for the handful of things SwiftUI doesn't reach on macOS (the window's title bar, dragging the window by an empty part of the tab row), **WKWebView** for pages.
- One `Tab` per page. Its web view is built lazily — a tab restored from last session doesn't cost a process until you switch to it. That's most of why launching with twenty tabs is still instant. Each page runs in WebKit's own content process, as in Safari; a tab you close is really gone.
- The ad blocker is a `WKContentRuleList` compiled once at launch and enforced inside WebKit's networking, before a request is made — zero cost at run time, unlike a JavaScript blocker.
- Hidden elements are a per-site list of selectors injected as a stylesheet at document start, so nothing is ever seen appearing and vanishing.
- Every colour is a light/dark pair in `Design.swift`, resolved by the window's appearance; nothing else in the code knows which mode it is in.
- Extensions run on `WKWebExtension` (macOS 15.4+). `Crx.swift` fetches an extension from the Chrome Web Store's public update address and checks the CRX3 signature against the extension's id before anything is unpacked. `Extensions.swift` is the browser's side of WebKit's contract — tabs, the window, permissions, popups. `ExtensionShims.swift` adds, at install, a small script to the extension's worker, pages and content scripts: it defines the Chrome APIs WebKit lacks — `userScripts`, `privacy`, `browsingData`, `sessions`, the old FileSystem API and more — as calls answered natively by Cairn, and mends the places where WebKit behaves differently from Chrome: replies from pages that don't answer, listeners added after a worker starts, workers WebKit loses track of, members and constants it leaves out. Extension pages are served from `chrome-extension://<id>/`, the address they have in Chrome, so servers and sites recognise them. `./bench ext-*` drives all of it from the shell against a test run. `ExtensionNative.swift` speaks Chrome's native messaging to hosts registered in Chrome's `NativeMessagingHosts` folders.
- `Sources/Search/` is one file per concern: `Vault.swift` is the keychain, `Shield.swift` the ad blocker, `Curtain.swift` the hidden elements, `Session.swift` what comes back at launch, `Updater.swift` the update, `Bench.swift` the test socket, and so on. There's no framework of its own to learn first.

### Testing it without closing it

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

Each session starts this checkout's `build/Cairn.app` hidden, in a test world of its own, and wipes that world when it closes; the browser you use is never in reach. `python3 Tests/bench_mcp.py` checks it. This is not the browsing agent above: that is `cairn-mcp` (in the app), whose rules are in `Sources/Search/AgentControl.swift` and `python3 Tests/agent_control.py` and `Tests/agent_gate.py` check them in a hidden probe. [CLAUDE.md](CLAUDE.md) has the rules for changing any of it.

`python3 Tests/split_view.py`, after `./build.sh`, checks Split View through the app's own model in a hidden test run with its own settings and files, all removed afterwards. It never makes or shows a window; what can only be seen (dragging onto a page's edge, the divider under the pointer, the motion) is checked by hand on a release candidate.

### Contributing

This is a personal fork, kept small on purpose. The rules it inherits are in [CONTRIBUTING.md](CONTRIBUTING.md): small changes, no new dependencies, nothing that phones home, and anything new is minimal, optional and off by default. Found a security problem? Please report it privately, as [SECURITY.md](SECURITY.md) says. A fix for something that is also broken in Search is better sent to [Search](https://github.com/driceroland/Search) as well.

### License and credit

MIT — see [LICENSE](LICENSE), whose copyright notice (© 2026 Office Commun) stays as it is: this is their browser, and everything here began as their code. Cairn is a fork of [Search](https://github.com/driceroland/Search) by Office Commun; Settings › About says so too. They ask that forks be renamed and not reuse "Search" or the app icon. The name is Cairn. The name, the app icon and the mark are Cairn's own.
