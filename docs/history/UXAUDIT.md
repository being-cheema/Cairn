# Cairn UX audit: Settings, Passwords, suggestions, Welcome, themes

Branch `passkeys-1` at 5f5e1d7, audited 24 Nov 2026. This was a read-only review: no source was changed.

**How it was judged.** I read the SwiftUI source for every control. I looked at real screens from a hidden probe copy of the build, in light and dark: all 11 Settings pages, the Passwords page (All tab, empty state), the new-tab page and the Welcome screen.

The probe cannot click. So these were **judged from code only**: the Add/Edit form and its generator, the Detail pane with a password picked, Codes, Passkeys and Health with items in them, the import preview and done cards, the backup-passphrase, vault and export cards, the suggestion rows under form fields, and the Claude panel.

Contrast ratios were computed from `Design.swift` Palette values (WCAG 2.x formula).

Ranks: **Critical** means data loss, a broken promise or an accessibility blocker. **Major** means users will hit it or be misled. **Minor** is an irritant. **Polish** is a nicety.

---

## 0. Cross-cutting (fix once, fixes everywhere)

### C1. Critical: Switch and Segmented can't be reached by keyboard or VoiceOver
`Settings.swift:1634-1650` (`Switch`) and `Settings.swift:1577-1615` (`Segmented`) are a `Capsule`/`Text` with `.onTapGesture`. They are not a `Button` or `Toggle`.

- Tab and Full Keyboard Access never reach them.
- VoiceOver reads nothing: no role, no on/off value, no label.

Nearly every setting in the app is one of these. The same goes for the Welcome screen's switches (`Welcome.swift:485`).

**Fix:** make `Switch` a `Toggle` with a custom `ToggleStyle` that draws the same capsule. Add `.accessibilityLabel(title)` from the row's title (pass it through `SettingRow`). Make `Segmented` a row of `Button`s with `.accessibilityAddTraits(selected ? .isSelected : [])`, or use a `Picker` with a custom style.

### C2. Major: light-theme `muted` and `accent` fail WCAG AA for text
In light mode, `NS.muted` (0.55 grey) is **3.07:1** on the ground, 3.28 on white and 2.87 on `wash`. Every detail line, caption, tab label ("Codes", "Passkeys"…), the "0 passwords" foot and the Health explanations are 11.5–12pt. They need 4.5:1.

Light `accent` (0.784/0.380/0.247) is **3.76:1** on the ground. It fails for:

- the "‹ Settings" back link (`Plate.swift:50-57`, 13pt)
- error text (`Passwords.swift:745`, `:785`)
- the codes' "5s" countdown (`:293`)

Dark is fine: muted 6.3, accent 7.3.

**Fix:** set light `muted` to about 0.42 (about 4.9:1), and keep the old value as a new `quiet` for non-text only. Set light `accent` to about (0.70, 0.31, 0.19) (about 4.9:1). Recheck the filled pill (C3).

### C3. Major: filled Pill text fails contrast in light mode
`Pill` filled draws `Palette.ground` on `Palette.accent` (`Settings.swift:1731-1735`). In light mode that is **3.76:1** at 11.5pt. It affects "Add", "Make default", "Save", "Bring in", "Encrypted backup…", "Open", "Move the file to the Trash" and others. Dark is 7.3:1, which is fine.

**Fix:** use the darker light accent from C2, or ink text on a lighter coral.

### C4. Major: `Palette.faint` is used as a text colour
Faint is **1.38:1** in light and **2.57:1** in dark. It is meant for hairline-level marks, but it carries words in these places:

- the suggestion list footer "From your keychain" / "Made on this Mac, never sent anywhere", 10.5pt (`Accounts.swift:79`)
- "Other accounts on …" (`Accounts.swift:110`)
- "No username" in the Detail pane (`Passwords.swift:1025`)
- "and N more" in the import preview (`:594`)
- Welcome `Choice` details when not `plain` (`Welcome.swift:~481`)
- the Claude panel's placeholder "Ask Claude…" and its "· Claude Code on this Mac · may be wrong" disclaimer (`ClaudePanel.swift:174,193-195`)
- the Safari hint on Bring Things Over (seen on screen: nearly invisible)

The disclaimer and the "never sent anywhere" line are exactly the honesty copy the app depends on. Today they are the least legible text on screen.

**Fix:** use `muted` (after C2) for all text. Reserve `faint` for strokes, dots and disabled tracks.

### C5. Major: the off-state Switch track fails non-text contrast
In light mode, the off track is `faint` on the ground: 1.38:1 (WCAG 1.4.11 needs 3:1). Off toggles read as almost blank in `light-set-*.png`.

In dark mode, the knob is `Palette.ground` (near black). So:

- An **on** switch shows a black dot on coral, which reads as a hole rather than a knob (`dark-set-privacy.png`).
- An **off** switch is a dark knob on a 0.35 track. It is barely distinguishable from the disabled "Sync with iCloud" switch on the same page.

**Fix:** draw the knob in white in both themes. Make the off track at least `muted` at 0.5 opacity plus a 1px `hairline` stroke. Show the disabled state with 0.4 opacity and no knob shadow, so it differs visibly from off.

### C6. Major: disabled state on Pill and Quick (judged from code)
`Pill` and `Quick` set an explicit `foregroundStyle` and `background` inside a `.plain` button. They do not read `isEnabled`. Disabled "Save", "Bring in", "Open", "Save backup…" and "Encrypted backup…" may look exactly like enabled ones: a coral pill that does nothing.

The Extensions page's own "Add" does dim (seen on screen), so the app is inconsistent.

**Fix:** read `@Environment(\.isEnabled)` in `Pill` and `Quick`, and use 0.4 opacity when false.

### C7. Major: no visible keyboard focus on custom controls
These are all `.buttonStyle(.plain)` with no focus ring:

- the Passwords tab strip (`Passwords.swift:124-143`)
- the list rows (`:983`, `.onTapGesture`, not focusable at all)
- Health tiles, Pill, Quick, Door and the suggestion rows

The list rows have no ↑/↓ navigation and no Delete key. With Full Keyboard Access on, the pills get the system ring but the rows can't be reached.

**Fix:** make `Row` a `Button` with `.focusable()`. Handle `.onKeyPress(.upArrow/.downArrow)` in the list to move the selection. Mark the current tab in the strip with `.accessibilityAddTraits(.isSelected)`.

### C8. Minor: tap targets are small
- `Quick` is about 22pt tall.
- `Pill` is about 24pt tall.
- The `Switch` hit area is 30×18 (the capsule only).
- The Hunt clear "x" is an 11pt glyph with no padding (`Plate.swift:239-245`).

**Fix:** use `contentShape` with at least 28pt height on Pill/Quick. Give the switch `.contentShape(Rectangle().inset(by: -6))`. Pad the clear button to 20×20.

### C9. Major: destructive NSAlerts make the destructive button the Return default
The first-added button gets Return:

- Remove passkey (`Passwords.swift:361-363`, "Remove" first)
- Delete iCloud data (`Settings.swift:587`)
- Write plain CSV (`Passwords.swift:841`)

`Browser.forgetShown` already does this correctly with `Ask.sure(..., returnCancels: true)`.

**Fix:** route all three through `Ask.sure(returnCancels: true)`, or set `hasDestructiveAction = true` and give the Cancel/Keep button `keyEquivalent = "\r"`.

---

## 1. Passwords page: All tab (list, Detail, Add/Edit)

### P1. Critical: "Remove" in the Detail pane deletes with no confirmation and no Touch ID
`Passwords.swift:1074` calls `forget`. That calls `browser.forget(login)` (`Browser.swift:1378-1381`), which calls `Vault.forget` immediately.

This contradicts the app's own copy in Settings › Stay unlocked (`SettingsIndex.swift:591`): "Showing, copying and removing a password always ask first." Remove All asks twice (a sheet and Touch ID). A single Remove, sitting a few hundred points from Edit, asks nothing and can't be undone.

**Fix:** wrap it in `Ask.sure("Remove the password for \(host)?", confirm: "Remove", returnCancels: true)` followed by `Vault.Unlock.ask("remove the password for …")`, the same as `forgetShown`.

### P2. Major: the generator row overflows the Edit form (judged from code)
The detail card is about 464pt wide inside its padding: 816 − 300 − 16 − 36. The generator `HStack` (`Passwords.swift:1205-1236`) asks for:

| Piece | Width (pt) |
|---|---|
| Segmented picker | 180 |
| "Length 20" stepper | about 80 |
| "Symbols" checkbox | about 70 |
| "Very strong" | about 62 |
| "Generate" pill | about 70 |
| Spacing | 40 |
| **Total** | **about 500** |

Expect "Symbols" or the strength label to truncate, or the pill to clip.

**Fix:** put the generator on two lines. Line one: style picker plus "Generate". Line two: length/words, symbols and the strength label. Alternatively narrow the picker to 150.

### P3. Major: editing anything resets the "changed" date
`EditForm.keep` (`Passwords.swift:1260-1261`) always writes `changed: Date()`. Fixing a typo in Notes therefore clears the account from Health › Old, even though the password is a year old. That makes Health dishonest.

**Fix:** set `changed` to `Date()` only when `password != existing?.password`, and keep `existing?.extras.changed` otherwise.

### P4. Minor: Cancel discards edits silently
Cancel (`Passwords.swift:1184`), or picking another row, throws away typed changes with no prompt.

**Fix:** when the fields differ from the original, ask "Discard changes?" with Return on Keep editing.

### P5. Minor: Copy username and Copy code give no feedback and are never cleared
Password Copy announces "Password copied" and clears after 90 seconds as concealed and transient (`Browser.swift:1427-1446`).

- Username Copy (`Passwords.swift:1094-1097`) is silent.
- Codes' Copy (`:295-298`) is silent, persistent and not marked concealed. An OTP stays on the clipboard and in clipboard-manager history.

**Fix:** share one helper with password Copy (concealed, transient, `.currentHostOnly`, cleared after 30 seconds for codes). Announce "Code copied" / "Username copied".

### P6. Minor: the empty state says the same thing twice
On screen, the list says "Nothing kept yet. Sign in somewhere and say yes, or add one." The empty detail card says "Add a password, or bring yours in." A search field also shows with nothing to search.

**Fix:** with zero passwords, hide the search field and the list card. Make the detail pane the single empty state, with two buttons: Add (filled) and "Import & export" (which switches tab).

### P7. Minor: wording differs between the list and the suggestions
Empty usernames read "No username" in the list and Detail (`:967`, `:1023`) but "No name" in the suggestions (`Accounts.swift:129`).

**Fix:** use "No username" everywhere.

### P8. Polish: show a hint while the password is revealed
The reveal hides itself after 15 seconds (`:1106`), which is good, but nothing says so.

**Fix:** add a small "Hides in 15s" hint in `muted` next to Hide.

### P9. Polish: the selected row is coral, which breaks the Settings pattern
The selected row wash is `accent.opacity(0.12)` (`:981`). In dark mode that reads as muddy brown. Settings uses ground plus a shadow for selection.

**Fix:** pick one selection treatment for both lists.

---

## 2. Codes tab (judged from code)

### K1. Major: opening the tab triggers Touch ID, and a refusal bounces you away
Switching to the tab fires `Vault.Unlock.ask` (`Passwords.swift:98-100,257-262`). A refusal sets `tab = .all`. Health does the same (`:377-378`). A tab change that throws a system auth sheet without any explicit action is surprising. Being thrown back to All on Cancel feels like a bug.

**Fix:** show the tab with its explanation and a filled "Show codes" / "Check passwords" Pill. Only that button asks. On refusal, stay on the tab and show "Not unlocked."

### K2. Minor: "Reading…" is the only loading state
"Reading…" sits inside the empty-state card with the "approval" art (`:230`), so loading looks like emptiness.

**Fix:** use a `ProgressView().controlSize(.small)` with "Reading…", and no art.

### K3. Polish: the countdown only changes colour
The countdown turns accent at 5 seconds or less (`:293`). Colour alone conveys the warning.

**Fix:** also add a thin progress ring, or keep the colour and set `.accessibilityValue("\(left) seconds left")`.

---

## 3. Passkeys tab (judged from code; empty state per `passkeysTab`)

### K4. Minor: the footer is long and jargony
The footer (`Passwords.swift:345`) is 4 lines of 11.5pt muted text that mentions "a paid developer's app". The point to get across is: "Passkeys you make here stay on this Mac. iCloud Keychain passkeys can't be used here: sign in another way once, then make a new one."

**Fix:** trim the footer to two sentences and move the Apple detail into a `.help` tooltip or an ⓘ.

### K5. Minor: Settings and the Passkeys tab disagree
The Settings line `passkeys` has the static detail "Touch ID or an iCloud passkey, on sites that offer one" (`SettingsIndex.swift:594`). The dynamic override (`Settings.swift:489-494`) says iCloud passkeys *can't* be used. Find-a-setting results show the static, now-wrong text.

**Fix:** update the static detail to match `SoftPasskeys.on`.

### K6. Polish: Remove is styled like a neutral action
Row "Remove" is a neutral `Quick` while the Detail pane's Remove is red.

**Fix:** use one tint for destructive row actions app-wide.

---

## 4. Health tab (judged from code)

### H1. Minor: an active filter survives a re-check
`healthFilter` persists when the report is recomputed (`:103`). After fixing the last "Weak" one, you see "Nothing under Weak." even though others remain.

**Fix:** reset the filter when its count drops to 0.

### H2. Minor: the tile label "Over http" is jargon
**Fix:** "Sent unencrypted", keeping the http detail in the tooltip. The tooltips themselves (`:424-427`) are hover-only and so invisible to keyboard users. Put the one-liner under each number.

### H3. Polish: a zero count reads as disabled
A zero count is shown in `muted` (`:414`), which reads as disabled while the tile can still be clicked.

**Fix:** keep ink, or make zero tiles non-interactive.

---

## 5. Import & export tab (judged from code)

### I1. Major: "Remove All…" here obeys a search typed on another tab
The red "Remove All…" / "Remove N…" (`Passwords.swift:530-539`) sits on Import & export. Its scope is `browser.hunting`, the search field on the **All** tab, which is not visible here. Someone who searched "git" earlier sees "Remove 3…" with no idea which three.

The sheet text helps, but the control's location and scope are wrong.

**Fix:** move it to the All tab under the list ("Remove these 3…"), or clear the search when entering this tab and always say "Remove all N…".

### I2. Major: the passphrase form has no live length feedback, and cancelling loses it
The minimum length appears only in the placeholder (`:775`), which vanishes once typing starts. Save stays disabled with no reason given.

"Save backup…" also clears both fields *before* the save panel opens (`:788-790`). If the user cancels the panel, they must retype the passphrase.

**Fix:** show "At least N characters (M more)" under the field until it is met. Clear the fields only after a successful write.

### I3. Minor: too many buttons in the source card
"Bookmarks and history file…" sits in the Passwords import card (`:490`), off-topic here, as a third equal pill.

**Fix:** drop it, or move it to Bring Things Over.

### I4. Minor: errors are drawn in the brand coral
`openError` and the "don't match" line use the accent (`:745`, `:785`), the same colour as the primary action.

**Fix:** pair an `exclamationmark.circle` glyph with the text so the error doesn't rely on hue, and fix contrast per C2.

### I5. Polish: say how many were trashed on the done card
After "Move the file to the Trash" the done card only says "In the Trash".

**Fix:** "\(filename) moved to the Trash".

What is good here: the preview-before-commit, the plain-CSV warning, `0600` permissions on exports, "Move it to the Trash" after export, and honest "keychain refused" counts are all excellent.

---

## 6. Suggestion rows under sign-in, new-password and code fields (`Accounts.swift`, judged from code)

### A1. Major: footer and section header are unreadable
The footer and the "Other accounts on …" header are `faint` at 10.5pt (1.38 light, 2.57 dark). See C4. The row detail (`:206`) is muted at 10.5pt: 3.07 in light.

**Fix:** use muted at 11pt or larger, after C2.

### A2. Minor: no way to reach the Passwords page from the list
Every comparable browser offers this.

**Fix:** add a last row or a footer link, "Passwords…", which calls `browser.lead(to: .passwords)`.

### A3. Minor: login rows don't look like the Passwords page
Login rows show the username's first letter. The Passwords page shows the site's favicon (`Passwords.swift:961`), so the same account looks different in the two places.

**Fix:** use `Mark(icon: Favicons.shared.cached(login.host), …)`.

### A4. Polish: the strong-password suggestion doesn't preview its kind
The suggestion row reads "Made here. Also fills the confirm box". Consider "Random, 20 characters · fills both boxes", from `PasswordGenerator.Options.saved`, so the choice made in Add is visible here.

The code row shows no code, which keeps OTPs out of the page/model surface. That is good: keep it.

---

## 7. Settings: every page

Seen in both themes: `light-set-*.png`, `dark-set-*.png`.

### S1. Critical: Privacy › Clear History and Sign out of everything act on one click
`Settings.swift:888-891` calls `clearHistory()`, `clearSites()`, `clearCache()` and `forgetCaptureChoices()` directly. None of them asks first.

- "Sign out of everything" logs the user out of every site in the profile.
- "History · Clear" wipes all spaces' history, archived tabs, favicons and site searches (`Browser.swift:1722-1745`).

Both are irreversible and sit as neutral outline pills next to "Clear cache". History's own panel offers a scope choice (`historyScopes`); Settings skips it.

**Fix:** use `Ask.sure(…, returnCancels: true)` for History, Cookies and Forget choices. Give the History sheet the same scope picker as the History panel. Cache can stay one-click.

### S2. Major: dead update controls on About
The "Updates" row says "This copy has no update feed, so it never looks." Directly below it, "Install updates on its own" and "Show when an update is ready" are **on and enabled** (`light-set-about.png`, `Settings.swift:918-920`). "No packages offered right now — They come with the next check for updates" promises a check that never happens.

**Fix:** when `!Updater.configured`, disable both switches (with C5's disabled look). Change the Developer Tools line to "Not offered in this build".

### S3. Major: Welcome offers Sync with iCloud that this build can't do
The Welcome screen shows a live "Sync with iCloud" switch (`Welcome.swift:117`, `dark-welcome.png`). Settings › General shows the same switch disabled with "Needs a build of Cairn signed for iCloud".

**Fix:** in Welcome, hide the row or show it disabled with the same reason when iCloud is unavailable.

### S4. Minor: the Themes preview placeholder doesn't match the real new tab
The preview reads "Search or enter address" (`ThemesPage.swift:103`). The real new tab reads "Enter a web address" (`Omnibox.swift:569`).

The page also uses the native segmented `Picker` (`ThemesPage.swift:34`) while every other page uses `Segmented`. It has one row, whose caption "HOME BACKGROUND" repeats the row title "Home background".

**Fix:** read the placeholder from the same constant, use `Segmented(wide: true)`, and drop the redundant caption (or rename the page "Home background").

### S5. Minor: Extensions breaks the Settings page grammar
Extensions uses separate cards with bold titles, no section captions and no row icons, so it reads as a different app. The Bring Things Over page differs too.

**Fix:** reuse `GroupBlock`/`SettingRow`: an "Add" group (store, another browser, unpacked, Safari apps) and an "Installed" group.

### S6. Minor: copy points to a place that doesn't exist
"The kind and length are chosen in Settings › Passwords › Add" (`SettingsIndex.swift:587`). Add lives on the Passwords **page**, not in Settings.

**Fix:** "…in Passwords › Add (Open… above)", or add a generator default row to Settings › Passwords.

### S7. Minor: Settings › Passwords ordering and defaults
- "Stay unlocked for five minutes" sits between "Suggest strong passwords" and "Offer passkeys". It belongs beside "Ask for Touch ID before filling", since both are lock behaviour.
- "Ask for Touch ID before filling" defaults **off** while "Stay unlocked" defaults **on**. With these defaults, any person at an unlocked Mac can fill saved passwords into pages. That is a product call, but worth a deliberate decision.

### S8. Minor: the selected sidebar row in dark mode is darker than the sidebar
In dark mode the selected row is `Palette.ground` on the sidebar's lighter frame grey. The selection is therefore *darker* than its column, at about 1.1:1, and is carried only by bold weight (`dark-set-general.png`).

**Fix:** use `greys.wash` or `wash` for the selected row in dark mode.

### S9. Polish: title-case mismatches
Row titles use sentence case ("Bring things over") while their buttons use title case ("Bring Things Over…", "Send Feedback", "What's New…"). "Open the Store" and "Bring them over…" sit on the same page.

**Fix:** pick sentence case for buttons app-wide, as Settings rows already do.

### S10. Polish: sidebar icons and title don't match
Sidebar icons have mixed optical weights: Themes' `photo.artframe` and Spaces' `square.stack` look heavier than the rest. The sidebar title "Settings" is bold sans while every page heading is serif.

**Fix:** use the serif `Typeface.heading` for the sidebar title.

### S11. Polish: the About header shows two pictures
The illustration and the logo sit side by side, which competes.

**Fix:** keep one.

---

## 8. Dark theme (neutral charcoal) and art

### D1. Major: spot illustrations sit on white tiles in dark mode
The "approval", extensions and Welcome art are paper-white rectangles (`dark-passwords.png`, `dark-set-extensions.png`, `dark-welcome.png`). On the new charcoal they are the brightest thing on screen and look pasted on.

**Fix:** give `ArtPicture` a dark variant: line art in `ink` on clear, coral fills kept. Failing that, draw the tile in `wash` with the art's paper knocked out (multiply blend in light, screen in dark).

### D2. Minor: the live tab is warm brown on a neutral charcoal
The live tab is `greys.wash` plus `accent.opacity(0.10)` (`TabBar.swift:1236`). On charcoal that measures (74, 66, 62), a warm brown, which is exactly the "orange greys" the charcoal change set out to remove. The new-tab field's coral border reads brown too.

**Fix:** use 0.05 opacity in dark mode, or a neutral wash with a 2px coral underline.

### D3. Polish: two Settings windows in one probe run
The probe opened two windows (Settings tab, then a blank one). This was not investigated: it may be probe-only.

---

## 9. Claude panel and new tab (from code plus the new-tab screenshot)

### N1. Major: the panel's disclaimer and placeholder are faint
"may be wrong" and the "Ask Claude…" placeholder are `faint` (see C4). The empty state's "I work in a clean browser of my own: not signed in…" is honest and good. Keep it at `muted` or stronger.

### N2. Minor: the step list is faint
The step list uses `faint` for finished steps and for "N earlier steps" (`ClaudePanel.swift:285-301`).

**Fix:** use `muted`.

### N3. Polish: the new-tab field is a lone empty field
On the new tab, the field with "Enter a web address" is centred on an empty page with no hint of ⌘L/⌘T or the Claude panel. That is fine for minimalism. Consider a single muted line of recent sites when `newtab.recent` is on, since the setting exists.

---

## 10. Rules check (never reaching the model, nothing phoning home)

- Password, card and OTP values: the suggestion rows show no secret, and Codes and Health read secrets off-main after Touch ID and keep only findings. Reveal auto-hides, and Copy is concealed and transient for passwords. **One gap:** OTP Copy and username Copy bypass that helper (P5).
- Health states that nothing is sent and that this is why there is no breach lookup. That is honest and correct.
- The About "Send Feedback" opens a mail draft (user-initiated). Updates are inert without a feed. No phoning home was found in these screens.

---

## What is already good

- **One system:** Plate, Card, Rule, Line, Caption, Hunt and Nothing make Settings, Passwords, History and Bookmarks read as one product. Serif headings and coral used sparingly hold up in both themes.
- **Honest copy everywhere:** the plain-CSV warning, "There is no way to open the backup without it", "Checked on this Mac … nothing was sent", the passkey-limits footnote and the agent's "clean browser of my own".
- **A careful security model:** Touch ID before show/copy/export, a 15s auto-hide, concealed and transient clipboard with a 90s clear, `0600` export files, preview before import, "move the file to the Trash" nudges, and Remove All asking twice with Return on Cancel.
- **Settings search** (Find a setting, ⌘F) with per-page match counts, and contextual details (default browser, iCloud availability) that explain *why* a control is off.
- **Dark theme:** the neutral charcoal itself is clean. Ink 15.7:1, muted 6.3:1 and accent 7.3:1 all pass comfortably.
- **Suggestion list:** placement above or below by available room, keyboard ↑/↓/Return, and an "Other accounts on …" split for parent-domain logins.

---

## Suggested order of work

1. P1 (single Remove with no confirmation or unlock) and S1 (Clear and Sign out with no confirmation).
2. C1 and C7 (Switch, Segmented and list rows reachable by keyboard and VoiceOver).
3. C2–C5 (palette: light muted and accent, no faint text, switch track and knob).
4. S2, S3 and I1 (dead or misleading controls), C9 (Return on destructive alerts), P2 (generator overflow), P3 (Health dates).
5. D1 (art in dark), then the Minors and Polish.
