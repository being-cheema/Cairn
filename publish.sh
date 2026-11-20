#!/bin/bash
# Puts the three files the site serves into the site: the disk image for
# people, the ZIP for the updater, and the appcast that names them both.
#
#   ./publish.sh "../site/public/cairn"
#   SEARCH_ARCH=x86_64 ./publish.sh "../site/public/cairn"
#
# ./build.sh release ship makes them first (release dmg makes them too, but
# unnotarised — fine for trying, not for anyone else's Mac). The names never
# change, so the site's links never have to. The Intel build (build/intel/)
# goes into the folder's intel/, where Intel builds of Cairn look.
set -euo pipefail

cd "$(dirname "$0")"
[ $# -eq 1 ] || { echo "usage: ./publish.sh <folder>" >&2; exit 1; }
ARCH="${SEARCH_ARCH:-arm64}"
case "$ARCH" in
  arm64) FROM="build"; FOLDER="$1" ;;
  x86_64) FROM="build/intel"; FOLDER="${1%/}/intel" ;;
  *) echo "SEARCH_ARCH is arm64 or x86_64, not “$ARCH”" >&2; exit 1 ;;
esac
FILES=(Cairn.dmg Cairn.zip appcast.json appcast.json.zip)

for FILE in "${FILES[@]}"; do
  [ -f "$FROM/$FILE" ] || { echo "$FROM/$FILE is missing — ./build.sh release dmg makes it" >&2; exit 1; }
done
# This version's files, for this chip — not ones left from an earlier build.
VERSION="$(tr -d '[:space:]' < VERSION)"
grep -q "\"version\": \"$VERSION\"" "$FROM/appcast.json" \
  || { echo "$FROM/appcast.json isn't $VERSION — build it again first" >&2; exit 1; }
CHIP="$(mktemp -d)"
ditto -x -k "$FROM/Cairn.zip" "$CHIP"
[ "$(lipo -archs "$CHIP/Cairn.app/Contents/MacOS/Cairn")" = "$ARCH" ] \
  || { rm -rf "$CHIP"; echo "$FROM/Cairn.zip doesn't hold a $ARCH app — not publishing" >&2; exit 1; }
rm -rf "$CHIP"
# The signed feed has to hold up before it goes anywhere: builds from 1.0.4
# read only it, and a broken one would stop every update without a word.
CHECK="$(mktemp -d)"
ditto -x -k "$FROM/appcast.json.zip" "$CHECK"
# Whose feed it is: the bundle id and team of the build (build.sh's variables).
BUNDLE_ID="${CAIRN_BUNDLE_ID:-$(sed -n 's/^ *static let bundleID = "\(.*\)"$/\1/p' Sources/Search/Brand.swift | head -1)}"
[[ "${CAIRN_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || { rm -rf "$CHECK"; echo "CAIRN_TEAM_ID is the Developer ID team that signed the feed" >&2; exit 1; }
codesign --verify -R="anchor apple generic and identifier \"$BUNDLE_ID.appcast\" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$CAIRN_TEAM_ID\"" "$CHECK/appcast.json" \
  || { rm -rf "$CHECK"; echo "$FROM/appcast.json.zip doesn't verify — not publishing" >&2; exit 1; }
cmp -s "$CHECK/appcast.json" "$FROM/appcast.json" || { rm -rf "$CHECK"; echo "the signed appcast isn't $FROM/appcast.json — not publishing" >&2; exit 1; }
rm -rf "$CHECK"
xcrun stapler validate -q "$FROM/Cairn.dmg" >/dev/null 2>&1 \
  || echo "note: $FROM/Cairn.dmg is not notarised — ./build.sh release ship does that" >&2

mkdir -p "$FOLDER"
# The AI engine the feed names, when it names one (build.sh, write_engine):
# only a file whose hash is the one in the feed.
ENGINEURL="$(python3 -c 'import json,sys; e=json.load(open(sys.argv[1])).get("ai",{}).get("engine"); print(e["url"] if e else "")' "$FROM/appcast.json")"
if [ -n "$ENGINEURL" ]; then
  ENGINEFILE="$FROM/ai/$(basename "$ENGINEURL")"
  WANT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ai"]["engine"]["sha256"])' "$FROM/appcast.json")"
  [ -f "$ENGINEFILE" ] && [ "$(shasum -a 256 "$ENGINEFILE" | cut -d' ' -f1)" = "$WANT" ] \
    || { echo "the engine the feed names isn't $ENGINEFILE with its hash — not publishing" >&2; exit 1; }
  mkdir -p "$FOLDER/ai"
  cp "$ENGINEFILE" "$FOLDER/ai/"
  echo "copied: $ENGINEFILE → $FOLDER/ai/"
fi
for FILE in "${FILES[@]}"; do
  cp "$FROM/$FILE" "$FOLDER/$FILE"
  echo "copied: $FROM/$FILE → $FOLDER/$FILE"
done
