#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${INODE_BUILD_DIR:-$ROOT/../../work/inodearm-build}"
APP="$ROOT/../iNode for Mac.app"
if [[ ! -f "$ROOT/GatewayPolicy.json" ]]; then
    echo "缺少配置文件 $ROOT/GatewayPolicy.json，请先复制 GatewayPolicy.example.json 为 GatewayPolicy.json 并填写默认网关地址。" >&2
    exit 1
fi
python3 "$ROOT/scripts/compile_policy.py" "$ROOT/GatewayPolicy.json" "$BUILD/GatewayPolicy.swift"
mkdir -p "$BUILD/swift-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
MACOSX_DEPLOYMENT_TARGET=13.3 CARGO_PROFILE_RELEASE_STRIP=false CARGO_TARGET_DIR="$BUILD/rust-macos13.3" cargo +1.92.0 build --locked --release --bin inode-desktop --manifest-path "$ROOT/vendor/inode-cli/Cargo.toml"
cp "$BUILD/rust-macos13.3/release/inode-desktop" "$APP/Contents/MacOS/inode-desktop"
codesign --force --options runtime --identifier local.vision.inode-arm.core --sign - "$APP/Contents/MacOS/inode-desktop"
CORE_HASH="$(codesign -dv --verbose=4 "$APP/Contents/MacOS/inode-desktop" 2>&1 | sed -n 's/^CDHash=//p')"
[[ "$CORE_HASH" =~ ^[a-f0-9]{40}$ ]]
printf 'let trustedCoreCDHash = "%s"\n' "$CORE_HASH" > "$BUILD/TrustedCore.swift"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx13.3 -module-cache-path "$BUILD/swift-cache" "$ROOT/Sources/ServiceProtocol.swift" "$ROOT/Service/NetworkService.swift" "$ROOT/Service/SessionLauncher.swift" -o "$BUILD/inode-service"
codesign --force --options runtime --identifier local.vision.inode-arm.service --sign - "$BUILD/inode-service"
SERVICE_HASH="$(codesign -dv --verbose=4 "$BUILD/inode-service" 2>&1 | sed -n 's/^CDHash=//p')"
[[ "$SERVICE_HASH" =~ ^[a-f0-9]{40}$ ]]
printf 'let trustedServiceCDHash = "%s"\n' "$SERVICE_HASH" > "$BUILD/TrustedService.swift"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx13.3 -module-cache-path "$BUILD/swift-cache" "$ROOT/Sources/ServiceProtocol.swift" "$ROOT/Sources/ServiceClient.swift" "$BUILD/TrustedService.swift" "$ROOT/Sources/ConnectionJournal.swift" "$ROOT/Sources/ConnectionHistoryView.swift" "$ROOT/Sources/Application.swift" "$ROOT/Sources/App.swift" "$ROOT/Sources/Connections.swift" "$ROOT/Sources/ContentView.swift" "$BUILD/GatewayPolicy.swift" "$ROOT/Sources/SocketEvents.swift" "$ROOT/Sources/Credentials.swift" "$ROOT/Sources/LocalPasswords.swift" "$ROOT/Sources/CoreIdentity.swift" "$BUILD/TrustedCore.swift" -o "$APP/Contents/MacOS/iNodeForMac"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/vendor/inode-cli/LICENSE" "$APP/Contents/Resources/inode-cli-LICENSE.txt"
xcrun swift -module-cache-path "$BUILD/swift-cache" "$ROOT/scripts/make_icon.swift" "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --sign - "$APP"
codesign --verify --deep --strict "$APP"
file "$APP/Contents/MacOS/iNodeForMac" "$APP/Contents/MacOS/inode-desktop"
