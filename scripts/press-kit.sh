#!/bin/sh
# Gera as telas do README em docs/screenshots a partir da fixture de record/replay (App/Sources/PressKit.swift).
set -eu
cd "$(dirname "$0")/.."
DD=.build/xcode-debug
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

xcodegen generate --quiet
xcodebuild -project QuietDeck.xcodeproj -scheme QuietDeck -configuration Debug -derivedDataPath "$DD" build -quiet
"$DD/Build/Products/Debug/QuietDeck.app/Contents/MacOS/QuietDeck" --press-kit "$OUT" \
  --fixture "$PWD/Packages/DeckRemote/Tests/DeckRemoteTests/Fixtures/steamos-3.9.4-demo.json" -AppleAccentColor 4 -AppleInterfaceStyle Dark

mkdir -p docs/screenshots
mv "$OUT"/*.png docs/screenshots/
ls docs/screenshots
