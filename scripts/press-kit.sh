#!/bin/sh
# Gera as telas do README em docs/screenshots a partir da fixture de record/replay (App/Sources/PressKit.swift).
set -eu
cd "$(dirname "$0")/.."
DD=.build/xcode-debug
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

scripts/generate-project.sh
xcodebuild -project QuietDeck.xcodeproj -scheme QuietDeck -configuration Debug -derivedDataPath "$DD" build -quiet
"$DD/Build/Products/Debug/QuietDeck.app/Contents/MacOS/QuietDeck" --press-kit "$OUT" \
  --fixture "$PWD/Packages/DeckRemote/Tests/DeckRemoteTests/Fixtures/steamos-3.9.4-demo.json" -AppleAccentColor 4 -AppleInterfaceStyle Dark -AppleLanguages '(en)'

mkdir -p docs/screenshots docs/media
mv "$OUT"/*.png docs/screenshots/
ffmpeg -y -loglevel error -i "$OUT/demo.mov" -vf "scale=1040:-2" -c:v libx264 -pix_fmt yuv420p -crf 26 -movflags +faststart docs/media/demo.mp4
ffmpeg -y -loglevel error -i "$OUT/demo.mov" \
  -vf "fps=10,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" docs/media/demo.gif
ls -lh docs/media
