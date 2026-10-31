#!/bin/sh
# Compila os plugins do Decky e gera os zips embutidos no app, no formato da loja do Decky.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for NAME in QuietHome QuietTune; do
  cd "$ROOT/Plugin/$NAME"
  [ -d node_modules ] || npm install --no-audit --no-fund --ignore-scripts --legacy-peer-deps
  ./node_modules/.bin/rollup -c
  STAGE=$(mktemp -d)
  mkdir -p "$STAGE/$NAME/dist"
  cp plugin.json package.json "$STAGE/$NAME/"
  if [ -f main.py ]; then cp main.py "$STAGE/$NAME/"; fi
  cp dist/index.js "$STAGE/$NAME/dist/"
  OUT="$ROOT/Packages/DeckKit/Sources/DeckKit/Resources/plugin/$NAME.zip"
  mkdir -p "$(dirname "$OUT")"
  rm -f "$OUT"
  (cd "$STAGE" && zip -q -X -r "$OUT" "$NAME")
  rm -rf "$STAGE"
  ls -l "$OUT"
done
