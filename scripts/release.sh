#!/bin/sh
# `make release`: build Release universal, assinatura ad-hoc e .dmg em dist/.
set -eu
cd "$(dirname "$0")/.."
scripts/build-app.sh
scripts/make-dmg.sh
