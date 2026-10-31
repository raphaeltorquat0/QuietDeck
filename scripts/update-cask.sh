#!/bin/sh
# Atualiza versão e sha256 de Casks/quietdeck.rb a partir do .dmg de `make release`.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)
DMG="${1:-dist/QuietDeck-$VERSION.dmg}"
[ -f "$DMG" ] || { echo "falta $DMG; rode make release" >&2; exit 1; }
SHA=$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/quietdeck.rb
echo "Casks/quietdeck.rb: $VERSION $SHA"
