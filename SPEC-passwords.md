# Spec: Cairn's own passwords

Status: approved ("do it"). Steps 0 and 1 are done. Branch per step, off `main`.
Defaults taken for the open questions: unlock for 5 minutes, the encrypted
file is the backup, health shows counts only.

## Why

Apple's Passwords helper only starts for a Developer ID–signed app (checked on
this Mac: the helper is killed at launch for ad-hoc and for Apple Development
signing alike). Cairn can't be that without a paid membership, so the only
passwords it can offer for sure are its own. It already has most of a manager;
this makes it a whole one.

## What is there already (Vault.swift, Passwords.swift, Accounts.swift)

- Each login is a keychain item (host + user), device-only, never synced, never
  in a private tab, plain-http logins kept apart (`clear`).
- Saved when you sign in and say yes; filled from a list under the box; a
  "never for this site" list.
- A Passwords page: search, add, show, copy, delete.
- Import: from other browsers' profiles, and one CSV in Chrome's shape.
- Rules that stay: password, card and one-time-code values never reach the
  model; Claude and agent tabs never fill; page text is data.

## What is missing

1. **Locking.** (The upstream has since added "ask Touch ID before filling", `prefs.asksBeforeFilling`; step 2 builds on it.) Showing, copying or exporting a password asks Touch ID or the
   Mac's password, then stays open for a few minutes and shuts on sleep.
2. **More than a password.** Title, several addresses, notes, a one-time-code
   secret, created/changed dates.
3. **A generator**, offered on sign-up and change-password boxes.
4. **Codes.** Verification codes made here (TOTP), shown live, filled into
   code boxes.
5. **Import from anywhere**, with a preview.
6. **Export and backup.**
7. **Health.** Reused, weak, old, kept over http.
8. **A better Passwords page.**
9. **Delete the dead Apple Passwords code** (about 1,500 lines, five test files).

## The design

### Storage

Same keychain, same two attributes that find an item (service = host,
account = user), so every saved login keeps working. The value becomes a small
JSON `{password, notes, totp, urls, title, changed}` for new and edited items;
an item whose value is a bare string is read as before and rewritten as JSON
the first time it is edited. Nothing is written outside the keychain; the app
keeps no copy and no index of secrets in memory beyond what is on screen.

### Locking

`LAContext` (Touch ID, or the Mac's password as the fallback), asked before
reveal, copy, export, and edit. Unlocked for 5 minutes by default, locks on
sleep, screen lock and quit. Filling a page does not ask (it never shows the
value), as now. A switch: "Ask before showing a password".

### Generator

Offered under a `autocomplete=new-password` box, and in the Add form.
Random (length 12–40, letters, digits, symbols, no look-alikes) or a
passphrase of words (word list bundled, no network). Accepted: filled into the
box and its confirm box, and saved with the site when the form is sent, so a
sign-up that fails midway never loses it. Never offered in a private tab.

### Codes (TOTP)

Paste an `otpauth://` link or a setup key; stored in the item. The page shows
the live six digits and the seconds left; under a code box the list offers
"Code for <account>" and fills it. RFC 6238 with CryptoKit HMAC, no
dependency. Apple's CSV export carries these (OTPAuth column), so they come
across with the import.

### Import

Drop a file on the Passwords page or press File…. The format is told by its
header, not by asking:

| Source | File |
| --- | --- |
| Passwords app (Apple) | CSV: Title, URL, Username, Password, Notes, OTPAuth |
| Chrome, Brave, Edge, Arc, Dia | CSV: name, url, username, password, note |
| Firefox | CSV: url, username, password, httpRealm, … |
| Safari | CSV (Export Passwords) |
| 1Password | CSV, or `.1pux` |
| Bitwarden | JSON or CSV |
| LastPass, Dashlane, KeePass | CSV |

Then a **preview**: how many are new, how many already here (same site and
account: skip, update, or keep both, one choice for the lot), how many couldn't
be read and why. Nothing is written until Bring in is pressed. After it, the
page says "now delete the file" and offers to move it to the Trash; the app
never keeps it. Importing from another browser's own profile stays as it is.

### Export and backup

- CSV in Chrome's shape, after unlocking, with the warning that it is plain text.
- An encrypted file (`.cairnvault`): AES-GCM with a key from a passphrase
  (PBKDF2 via CryptoKit/CommonCrypto), for moving to another Mac or a backup.
  Importing it asks for the passphrase.

### Health

Computed on this Mac, nothing sent anywhere: reused across sites, short or
common (a bundled list of the few thousand most common), not changed in over a
year, kept over plain http. A count on the Passwords page, and each row says
why. (A breach check would need a network call; left out unless you ask for it
as an opt-in later.)

### The page

Same pictures and serif as the rest. A list (site icon, name, account, a dot
for flags), a detail pane (copy, show, edit, code, notes, history of changes,
delete), tabs for **All · Codes · Health · Import & export**. A small card
under the box when a password changes ("Update the saved one?").

## Steps (one branch each; I stop after each to be tested)

0. **Apple card off.** Done.
1. **Delete the Apple Passwords code** and its tests. Done (branch `passwords-1-remove-apple`).
2. **Items and locking.** The JSON value, migration on edit, Touch ID gate.
3. **The page.** List, detail, add/edit, search, the four tabs' shells.
4. **Import.** Format detection, preview, duplicate choice, trash offer.
5. **Generator.** On sign-up boxes and in the Add form.
6. **Codes.** TOTP, live display, fill under code boxes.
7. **Export and health.** CSV, encrypted file, the health counts.

## Not doing

No sync through iCloud Keychain (needs the signed-app entitlement Cairn
lacks); the shared-folder Sync in Settings can carry the encrypted file later.
No browser extension, no network call, no master password of our own (the Mac's
login and Touch ID are the lock). No change to passkeys.

## Questions

1. Lock default: 5 minutes, or ask every time?
2. Is the encrypted `.cairnvault` enough for backup, or do you want it kept
   in a folder you pick, automatically?
3. Health: counts only, or also a "change this" action per row?
