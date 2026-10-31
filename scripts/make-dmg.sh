#!/bin/sh
# Empacota dist/QuietDeck.app em dist/QuietDeck-<versão>.dmg.
set -eu
cd "$(dirname "$0")/.."
APP=dist/QuietDeck.app
[ -d "$APP" ] || { echo "falta $APP; rode make release" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="dist/QuietDeck-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname QuietDeck -srcfolder "$STAGE" -format UDZO -ov "$DMG"
echo "$DMG"
