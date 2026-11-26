# iNode for Mac

面向 Apple Silicon、macOS 13.3 及更新版本的独立 iNode 兼容客户端，使用 SwiftUI 界面和 Rust 通信核心，支持 SSL VPN 与 Portal 同时在线。关闭主窗口后应用与连接继续运行，可通过菜单栏查看状态及操作连接，退出应用时断开连接。支持 Portal/SSL VPN 独立在线计时、跨重启累计时长、连接历史和日志导出。

## 项目文件

- `outputs/iNodeARM/`：完整源码、构建脚本、依赖源码、使用说明和验证记录。
- `outputs/iNode for Mac.app/`：已构建应用。
- `outputs/iNode-for-Mac-1.0.4.arm64.pkg`：当前安装包，包含应用和 VPN 后台服务。
- `outputs/卸载 iNode for Mac.command`：移除安装的应用和后台服务，保留个人配置。
- `outputs/iNode-for-Mac-*.arm64.zip`、`outputs/iNode-ARM-*.zip`：应用压缩包与历史版本，不能替代后台服务安装。
- `outputs/iNode-for-Mac-source.tar.gz`：原有源码归档。
- `outputs/iNode-ARM可行性分析.md`：早期可行性分析。

## 构建

需要 Xcode Command Line Tools、Python 3 和 Rust 1.92.0。首次构建前请先复制 `outputs/iNodeARM/GatewayPolicy.example.json` 为 `outputs/iNodeARM/GatewayPolicy.json`（该文件已被 `.gitignore` 忽略，不会提交到 Git），并填写默认 VPN 网关与 Portal 服务器地址。在项目根目录执行：

```sh
./outputs/iNodeARM/scripts/build.sh
```

运行 `./outputs/iNodeARM/scripts/package.sh` 可构建包含后台服务的安装包。安装和更新时退出旧应用，然后安装 `.pkg`；正常 VPN 连接不再通过脚本申请管理员授权。

应用生成于 `outputs/iNode for Mac.app`，默认构建缓存位于 `work/inodearm-build`，可通过 `INODE_BUILD_DIR` 指定其他缓存目录。

使用方式和功能边界见 [使用说明](outputs/iNodeARM/使用说明.md)，历史验证情况见 [验证记录](outputs/iNodeARM/验证记录.md)。可视化交互验证由用户自行完成。

## 迁入记录

2026-11-03 从 `/Users/vision/Documents/Codex/2026-11-02/wove/outputs/` 复制迁入全部项目产物，保留原目录和文件。未复制旧 `work/` 中的临时分析材料、构建缓存和日志；需要时可回查原目录。本次迁入未修改源码，未重新构建或运行应用。
