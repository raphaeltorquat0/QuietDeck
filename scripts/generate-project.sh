#!/bin/sh
# xcodegen não conhece o tipo do Icon Composer: sem este ajuste, AppIcon.icon vira arquivos soltos.
set -eu
cd "$(dirname "$0")/.."
xcodegen generate --quiet
perl -pi -e 's/(AppIcon\.icon \*\/ = \{isa = PBXFileReference; )/$1lastKnownFileType = folder.iconcomposer.icon; /' QuietDeck.xcodeproj/project.pbxproj
