#!/bin/sh
# Baixa da fonte oficial os homebrew do catálogo usados nos testes. Não ficam no repositório.
# Licenças em Packages/DeckKit/Sources/DeckKit/Resources/free-catalog.json.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/fixtures
python3 -I -c '
import json
for g in json.load(open("Packages/DeckKit/Sources/DeckKit/Resources/free-catalog.json")):
    print(g["download"], g["sha256"])
' | while read -r url sha; do
  f=".build/fixtures/$(basename "$url")"
  [ -f "$f" ] || curl -fsSL --retry 3 -o "$f" "$url"
  echo "$sha  $f" | shasum -a 256 -c - >/dev/null
done
