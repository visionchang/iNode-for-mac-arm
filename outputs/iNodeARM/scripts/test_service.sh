#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${INODE_BUILD_DIR:-$ROOT/../../work/inodearm-build}"
mkdir -p "$BUILD/swift-cache"
for generated in GatewayPolicy.swift TrustedCore.swift TrustedService.swift; do
    [[ -f "$BUILD/$generated" ]] || { echo '请先运行 build.sh' >&2; exit 1; }
done
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$BUILD/swift-cache" "$ROOT/Sources/ServiceProtocol.swift" "$ROOT/Service/SessionLauncher.swift" "$ROOT/scripts/TestNetworkService.swift" -o "$BUILD/TestNetworkService"
codesign --force --options runtime --sign - "$BUILD/TestNetworkService"
"$BUILD/TestNetworkService"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$BUILD/swift-cache" "$ROOT/Sources/App.swift" "$ROOT/Sources/Connections.swift" "$ROOT/Sources/Credentials.swift" "$ROOT/Sources/LocalPasswords.swift" "$ROOT/Sources/SocketEvents.swift" "$ROOT/Sources/CoreIdentity.swift" "$ROOT/Sources/ServiceClient.swift" "$ROOT/Sources/ServiceProtocol.swift" "$BUILD/GatewayPolicy.swift" "$BUILD/TrustedCore.swift" "$BUILD/TrustedService.swift" "$ROOT/scripts/TestConnections.swift" -o "$BUILD/TestConnections"
"$BUILD/TestConnections"
