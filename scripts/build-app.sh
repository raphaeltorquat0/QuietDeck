#!/bin/sh
# Compila o QuietDeck.app em Release (universal) e assina ad-hoc. Saída: dist/QuietDeck.app
# Versão: só em project.yml (MARKETING_VERSION e CURRENT_PROJECT_VERSION).
set -eu
cd "$(dirname "$0")/.."

BUILD=.build/release-app
BUILT="$BUILD/Build/Products/Release/QuietDeck.app"
LOG="$BUILD/xcodebuild.log"
STARTED="$BUILD/build-started"

yaml_value() { sed -n "s/^ *$1: \"\(.*\)\"$/\1/p" project.yml; }
VERSION=$(yaml_value MARKETING_VERSION)
BUILD_NUMBER=$(yaml_value CURRENT_PROJECT_VERSION)

command -v xcodegen >/dev/null && xcodegen generate --quiet

# Sem .app anterior, uma falha de build nunca reaproveita um produto antigo.
rm -rf "$BUILT" dist/QuietDeck.app
mkdir -p "$BUILD" dist
touch "$STARTED"
xcodebuild -project QuietDeck.xcodeproj -scheme QuietDeck -configuration Release \
  -derivedDataPath "$BUILD" -destination 'generic/platform=macOS' \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none" build -quiet > "$LOG" 2>&1 || {
    grep -E 'error:|\*\* BUILD' "$LOG" >&2 || tail -20 "$LOG" >&2
    echo "build falhou (log completo: $LOG)" >&2
    exit 1
}

fail() { echo "build inválido: $1" >&2; exit 1; }
[ -d "$BUILT" ] || fail "$BUILT não foi gerado"
[ "$BUILT/Contents/MacOS/QuietDeck" -nt "$STARTED" ] || fail "o binário é anterior a este build"
PLIST="$BUILT/Contents/Info.plist"
GOT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")
GOT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")
[ "$GOT_VERSION ($GOT_BUILD)" = "$VERSION ($BUILD_NUMBER)" ] \
  || fail "o app tem $GOT_VERSION ($GOT_BUILD) e o project.yml pede $VERSION ($BUILD_NUMBER); rode xcodegen generate"
for arch in arm64 x86_64; do
  lipo "$BUILT/Contents/MacOS/QuietDeck" -verify_arch "$arch" || fail "falta a arquitetura $arch"
done

cp -R "$BUILT" dist/
codesign --verify --deep --strict dist/QuietDeck.app
echo "dist/QuietDeck.app $VERSION ($BUILD_NUMBER)"
