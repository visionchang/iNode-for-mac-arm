#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${INODE_BUILD_DIR:-$ROOT/../../work/inodearm-build}"
STAGE="$BUILD/package-root"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Info.plist")
"$ROOT/scripts/build.sh"
[[ "$STAGE" == */package-root ]]
rm -rf "$STAGE"
mkdir -p "$STAGE/Applications" "$STAGE/Library/PrivilegedHelperTools/local.vision.inode-arm" "$STAGE/Library/LaunchDaemons"
ditto "$ROOT/../iNode for Mac.app" "$STAGE/Applications/iNode for Mac.app"
SERVICE="$STAGE/Library/PrivilegedHelperTools/local.vision.inode-arm"
cp "$BUILD/inode-service" "$SERVICE/inode-service"
cp "$ROOT/../iNode for Mac.app/Contents/MacOS/inode-desktop" "$SERVICE/inode-desktop"
cp "$ROOT/installer/uninstall.sh" "$SERVICE/uninstall.sh"
cp "$ROOT/installer/local.vision.inode-arm.service.plist" "$STAGE/Library/LaunchDaemons/"
codesign -dv --verbose=4 "$STAGE/Applications/iNode for Mac.app" 2>&1 | sed -n 's/^CDHash=//p' > "$SERVICE/client.cdhash"
[[ "$(cat "$SERVICE/client.cdhash")" =~ ^[a-f0-9]{40}$ ]]
chmod 0755 "$SERVICE" "$SERVICE/inode-service" "$SERVICE/inode-desktop" "$SERVICE/uninstall.sh"
chmod 0644 "$SERVICE/client.cdhash" "$STAGE/Library/LaunchDaemons/"*.plist
pkgbuild --analyze --root "$STAGE" "$BUILD/components.plist"
python3 - "$BUILD/components.plist" <<'PY'
import plistlib, sys
from pathlib import Path
path=Path(sys.argv[1])
components=plistlib.loads(path.read_bytes())
for item in components:
    item['BundleIsRelocatable']=False
path.write_bytes(plistlib.dumps(components))
PY
pkgbuild --root "$STAGE" --component-plist "$BUILD/components.plist" --scripts "$ROOT/installer/scripts" --identifier local.vision.inode-arm.installer --version "$VERSION" --install-location / --ownership recommended "$ROOT/../iNode-for-Mac-$VERSION.arm64.pkg"
