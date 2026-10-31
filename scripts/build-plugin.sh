#!/bin/sh
# Compila o plugin Quiet Home e gera o zip embutido no app, no formato da loja do Decky.
set -eu
cd "$(dirname "$0")/../Plugin/QuietHome"
[ -d node_modules ] || npm install --no-audit --no-fund --ignore-scripts --legacy-peer-deps
./node_modules/.bin/rollup -c
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/QuietHome/dist"
cp plugin.json package.json main.py "$STAGE/QuietHome/"
cp dist/index.js "$STAGE/QuietHome/dist/"
OUT="$OLDPWD/Packages/DeckKit/Sources/DeckKit/Resources/plugin/QuietHome.zip"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
(cd "$STAGE" && zip -q -X -r "$OUT" QuietHome)
ls -l "$OUT"
