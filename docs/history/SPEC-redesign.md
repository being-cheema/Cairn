# Spec: the hand-drawn redesign

Status: proposed, waiting for approval. Nothing here is built.
Branch per step, off `step3-spec`: `redesign-1-tokens` … `redesign-5-icons`.

## Why

Cairn is "a browser made by Claude, for Claude". Today it is neutral grey
(Design.swift `Palette`), with green and amber only for connection safety.
The wanted look is Anthropic's: warm paper, hand-made line, one coral accent,
shown through the icons8 styles Anthropic Claude Hand Drawn, Watercolor Line
and Wash, and Watercolor Sketch.

## The licence line (decided: icons8 art stays local)

- Your icons8 plan has no MCP access, so no clean SVG. What can be fetched
  without a plan is PNG at size "standard" (456 px) and low-res previews.
- icons8 art is not MIT. So it is **never committed**: it lives in
  `Local/Art/` (git-ignored, with a `.gitleaks`-safe README saying why) and
  is copied into the built app only on your Mac.
- The app must work with the folder empty: every picture is optional and
  falls back to a plain drawn shape. A clone of the repo looks right, only
  without the pictures.
- Not for distribution: a Cairn.app built with these pictures is for your own
  use. The DMG installer step refuses to run if `Local/Art/` has files.
- About and README get no icons8 claim, since the repo ships none.

## Look (tokens, step 1)

- Ground: warm paper (about #FAF7F2 light, #1E1B18 dark), not pure white/grey.
- Ink: warm near-black; muted/faint/hairline warm greys, same steps as today.
- Accent: one coral (about #D97757 light, #E58F70 dark) for the live tab,
  focus, the Approve button and links. Green/amber stay for safety.
- Shapes: softer radii. Type: system serif (New York) for headings and empty
  states, system sans for chrome.
- All colours stay light/dark pairs in `Palette`; nothing else knows which.

## Steps (one branch each, I stop after each to be tested)

1. **Tokens.** Palette, type, radii only. The whole app changes at once.
2. **Chrome.** Tabs, address bar, sidebar, bookmarks bar, find bar.
3. **Claude and empty states.** Panel welcome, new tab, empty
   bookmarks/history/downloads, hold/approve prompt, blocked states, using
   illustrations from `Local/Art/` (browser, coding, reading, approvals).
4. **Pages of the app.** Settings, About, import, passwords, extensions.
5. **Icons.** Replace the line icons (Icons.swift) with hand-drawn-feel ones.
   Where an icons8 icon is wanted it is also local-only; otherwise drawn here.

## Art list for `Local/Art/` (fetched by me, PNG standard)

Anthropic Claude Hand Drawn first, Watercolor Line and Wash for quiet states.
About 12 pictures: browser window, coding, reading, search, shield/approval,
bookmark, history, download, settings, private tab, error, welcome. If a style
lacks one I search another of your three styles; if none fits, that spot is
left plain.

## Not doing

No new dependencies, no network use at runtime (pictures are bundled files).
No redesign of the web page content. No change to behaviour, gates or tests.

## Checks per step

`swift build` with zero new warnings, `swift test` for the touched area,
screenshots in light and dark, and the app run with `Local/Art/` empty.

## Questions for you

1. Coral accent everywhere (live tab, links, focus), or only on the Claude
   panel and Approve? I suggest everywhere.
2. Serif headings: yes? I suggest yes, in empty states and About only.
