#!/bin/bash
# Publie une version de mFRAMES : build universel, notarisation (Developer ID), release GitHub avec mFRAMES.zip et son .sha256,
# que la mise à jour automatique de l'appli va chercher. Notes : _tools/changelogs/mFRAMES_<version>.txt (4 langues).
# Usage : ./release.sh [version]   (par défaut 1.0.0 ; le tag devient v<version>). À lancer sur demande seulement.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-1.0.0}"
NOTARIZE=/Volumes/SKYRIM/TOOLS/MAC/_tools/notarize_app.sh
DIST="$(mktemp -d)"
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "release : modifications non commitées" >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "release : pas synchronisé avec origin/main (push manquant)" >&2; exit 1; }
./tests/check_l10n.sh
VERSION="$VERSION" UNIVERSAL=1 NO_INSTALL=1 ./build_app.sh
APP_ENTITLEMENTS="$PWD/Resources/mFRAMES.entitlements" DIST="$DIST" "$NOTARIZE" mFRAMES.app
(cd "$DIST" && shasum -a 256 mFRAMES.zip > mFRAMES.zip.sha256)
python3 /Volumes/SKYRIM/TOOLS/MAC/_tools/release_notes.py mFRAMES "$VERSION" --sha "$DIST/mFRAMES.zip.sha256" -o "$DIST/notes.md"
gh release create "v$VERSION" "$DIST/mFRAMES.zip" "$DIST/mFRAMES.zip.sha256" --target main --title "mFRAMES $VERSION" --notes-file "$DIST/notes.md"
rm -rf "$DIST"
git fetch -q --tags origin || true          # l'étiquette de la publication numérote ensuite les builds locaux (build_app.sh)
echo "✓ https://github.com/starbudweiser/mFRAMES/releases/tag/v$VERSION"
