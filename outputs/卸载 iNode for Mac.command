#!/bin/bash
set -euo pipefail
TOOL=/Library/PrivilegedHelperTools/local.vision.inode-arm/uninstall.sh
echo '请先退出 iNode for Mac。本工具将移除应用和后台服务，保留个人设置、已保存凭据及在线记录。'
if [[ ! -f "$TOOL" ]]; then
    echo '未找到已安装的卸载工具。'
    exit 1
fi
sudo "$TOOL"
