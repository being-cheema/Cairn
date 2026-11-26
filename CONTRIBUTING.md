# Contributing

Cairn is a fork of [Search](https://github.com/driceroland/Search) by Office Commun (MIT), and keeps its contribution rules. This is a small, mostly-solo project, reviewed the same way it's written. Contributions are welcome. Yes, really. Even yours. A few things make one land faster.

## Before writing code

Talk first, type second. Future you says thanks.

For anything beyond a small fix, open an issue first describing what you want to change and why. It saves a rewritten pull request later if the direction doesn't fit.

## New features: off until someone turns them on

Nobody asked to wake up to a surprise toolbar. Nobody has ever asked for that.

Cairn stays small by default. Anything new that changes how the browser
looks or behaves — spaces, groups, a visible address bar, a new panel — is:

- **minimal**: the smallest version that does the job, in the app's own quiet style;
- **optional, and off by default**: someone who never asks for it never sees it;
- **findable**: a switch in Settings, and a mention in the welcome screens if it's a big one, so people know it's there to turn on.

Fixes and things every browser is expected to do (Tab moving between a form's fields, ⌘1–⌘9) don't need a switch. Before building a bigger feature, look at how other browsers do it and read what people asked for on its issue; [the upstream's old roadmap](docs/history/ROADMAP-upstream.md) lists where each request came from.

## Where things are tracked

- [docs/history/ROADMAP-upstream.md](docs/history/ROADMAP-upstream.md): the upstream's list of ideas and reports, as it stood when this fork was made. It is kept for reference and is not updated here (the `./ideas` tool that wrote it talked to the upstream's database and was removed).
- [CHANGELOG.md](CHANGELOG.md): what has changed since the last version. A pull request that fixes or adds something also adds its line under **Unreleased**, so the next update's notes write themselves.

## What tends to get merged

The way to our heart:

- **Small, focused changes.** One thing per pull request, easy to read start to finish.
- **No new dependencies.** The whole point of this app is staying small; a browser this size doesn't need a package for something Foundation or WebKit already does.
- **Matches the existing style.** Comments here explain *why*, not *what the next line does* — read a couple of existing files before adding a new one. No force-unwraps on anything that can plausibly fail (a network response, a file read, a keychain lookup).
- **Builds clean.** `swift build` with zero warnings you introduced.

## What doesn't

The way to a polite but firm "no":

- Rewrites of things that already work, for style reasons alone.
- Anything that phones home, adds analytics, or changes what leaves the app over the network — the README's *Privacy, concretely* table is that boundary.
- Vendoring Chromium or any other engine. This is a WebKit browser on purpose.
- A real key or token anywhere: in code, a test, an issue, a pull request or a pasted log. Tests use keys that are obviously made up. `gitleaks git --pre-commit --staged` with the repo's `.gitleaks.toml` catches most of them before a commit; it is worth running as a pre-commit hook.

## Review

Yes, Claude reviews pull requests to the browser made for Claude. We've noticed. We're choosing to be calm about it.

Pull requests are reviewed by the maintainer of this fork, usually with Claude Code doing a first pass on the diff before a human look. That means a review can be fast even when nobody's watching the repo in real time, but it isn't a guarantee of a same-day answer — this isn't anyone's full-time job. Pinging a stale PR after a couple of weeks is completely fine.

## Reporting a bug

"It's broken" is a mood, not a bug report. (Security hole? Stop. Go to [SECURITY.md](SECURITY.md). Do not pass the issue tracker.)

Open an issue with: what you did, what you expected, what happened instead, and your macOS version. A crash log, if there is one, lives at `~/Library/Application Support/Cairn/crash.log` — it only ever stays on your Mac unless you paste it into the issue yourself.
