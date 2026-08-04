#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/src/lib/version.sh" | sed -n 's/APP_VERSION="\([^"]*\)"/\1/p')"
APP="$ROOT/build/TNT.app"
DIST="$ROOT/dist"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"

cp "$ROOT/src/main.sh" "$APP/Contents/Resources/tnt.sh"
cp "$ROOT/src/launcher.sh" "$APP/Contents/MacOS/TNT"
cp "$ROOT/src/launch-command.sh" "$APP/Contents/Resources/Launch TNT.command"
cp "$ROOT/assets/TNT.icns" "$APP/Contents/Resources/TNT.icns"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/CHANGELOG.md" "$APP/Contents/Resources/CHANGELOG.md"
printf '%s\n' "$VERSION" > "$APP/Contents/Resources/VERSION"

chmod 755 \
  "$APP/Contents/MacOS/TNT" \
  "$APP/Contents/Resources/tnt.sh" \
  "$APP/Contents/Resources/Launch TNT.command"

for file in "$ROOT"/src/*.sh "$ROOT"/src/lib/*.sh; do
  /bin/bash -n "$file"
done

/usr/bin/plutil -lint "$APP/Contents/Info.plist"

rm -f "$DIST/TNT-${VERSION}.zip" "$DIST/TNT-${VERSION}.tar.gz"

(
  cd "$ROOT/build"
  /usr/bin/zip -qry "$DIST/TNT-${VERSION}.zip" "TNT.app"
)

/usr/bin/tar -czf "$DIST/TNT-${VERSION}.tar.gz" -C "$ROOT/build" "TNT.app"

echo "Built:"
echo "  $DIST/TNT-${VERSION}.zip"
echo "  $DIST/TNT-${VERSION}.tar.gz"
