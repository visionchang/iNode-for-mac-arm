#!/bin/bash
set -euo pipefail
if [[ "$EUID" != 0 ]]; then
    echo '请先退出 iNode for Mac，再使用 sudo 运行本卸载脚本。' >&2
    exit 1
fi
/bin/launchctl bootout system/local.vision.inode-arm.service >/dev/null 2>&1 || true
/bin/rm -f /Library/LaunchDaemons/local.vision.inode-arm.service.plist
/bin/rm -rf /Library/PrivilegedHelperTools/local.vision.inode-arm
/bin/rm -rf /private/var/run/local.vision.inode-arm
/bin/rm -rf '/Applications/iNode for Mac.app'
/bin/rm -rf '/Applications/iNode for mac arm.app'
/bin/rm -rf '/Applications/iNode ARM.app'
/usr/sbin/pkgutil --forget local.vision.inode-arm.installer >/dev/null 2>&1 || true
echo 'iNode for Mac 应用及后台服务已移除。个人设置、已保存凭据及在线记录予以保留。'
