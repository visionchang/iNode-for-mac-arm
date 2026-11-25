# iNode 原生 ARM 替代客户端可行性分析

检查日期：2026-11-02。范围：用户提供的 E0653 安装包，以及指定 VPN 网关的未登录页面。未安装或运行原客户端，未提交凭据、短信请求或验证码，未做可视化交互验证。

## 结论

具备开发原生 ARM 兼容原型的技术基础。不能将现有安装包直接转换成 ARM；需要重写或采用可编译为 ARM 的协议实现。当前证据尚不证明真实账号能够登录、建立隧道并访问内网。

## 安装包证据

- `iNodeTray`、`AuthenMngService`、`libiNodeSslvpnPt.dylib` 均为 x86_64。
- 排除符号链接后，共检测到 46 个仅 x86_64 的 Mach-O 文件、14 个 x86_64/arm64 双架构文件。
- 未发现 C/C++/Objective-C/Swift 源文件。
- VPN 库中存在 `NET_EXTEND / HTTP/1.1`、`IPADDRESS`、`SUBNETMASK`、`ROUTES`、IPv6 和排除路由字段，以及 `com.apple.net.utun_control`。
- 导出符号包含 `buildSsl2ndAuthPacketV7`、`buildSslChallengeAuthPacketV7`、`Format2ndLoginXML`、`FormatChallengeAuthXML`。这些是协议分析线索，不是源码，也不证明当前网关采用某一个特定分支。

## 目标网关的只读检查

目标：见本机 `outputs/iNodeARM/GatewayPolicy.json` 中的 `defaultGateway`。

1. HTTPS 可达，本次协商 TLS 1.3。
2. 根路径跳转至 `/domainlist/domainlist.html`。
3. 页面引用的公开配置 `/domain-path/wnm/domainlist/domainlist.json` 返回一个认证域：`duanxin`。
4. 进入该域后，公开登录页面为 `/login/login.html`，脚本为 `/login/login.js`。
5. `/wnm/login/login.json` 返回 `VLDCode=true`、`pwdauth=enable`、`DKey=false`，图片验证码地址为 `../vldimg.cgi`。

网关使用自签名证书。本次仅对无凭据的公开页面读取放宽 CA 校验；后续请求固定检查本次观察到的证书 SHA-256，避免研究过程中证书静默变化。这个观察值未经独立渠道验证，不能直接作为正式客户端的可信证书来源。

观察到的证书 SHA-256：`a1054e0951432a92e575ed485121b5fa5759de9737dad6a2ff9e56c97fe94f57`。

## 公开网页脚本确认的认证规则

以下为网页入口的静态代码行为，不等同于已验证原生客户端登录行为。认证提交接口没有被请求。

- 普通登录向 `/wnm/login/login_result.json` POST 表单：`user_name`、`password`、`browser`；验证码显示时另带 `vldcode`。
- 返回 `result=Challenge` 时，脚本读取 `type` 和 `dynamicPwd`；短信分支包括 `SMS`、`SMS-IMC`、`SMS-GW`。
- 短信提交向同一接口发送 `user_name`、`password`、`type`、`code`、`browser`。
- `SMS-IMC` 分支会组合三段数据：用户密码、服务器下发的动态挑战值、用户填写的短信码；标签分别为 0xb1、0xb2、0xb3。移植时需要忠实处理 JavaScript 字符串长度及表单编码，不能未经验证直接按字节拼接。
- `SMS-GW` 分支读取服务端返回的 `IntervalTime`；脚本也包含 `SMS-RESEND` 分支。
- 返回 `Success` 后网页进入主页。网页会话是否可用于 `NET_EXTEND`，仍须验证，不能把网页登录成功视为 VPN 隧道成功。

用户确认的原客户端操作顺序：账号密码 → 登录 → 图片验证码 → 系统发送短信 → 输入短信验证码 → 登录成功。原生替代版应保持这个操作顺序，但具体请求序列须由服务端响应决定。

## 实施范围与待验证项

建议先实现原生 ARM 协议原型，覆盖认证域选择、图片验证码展示与人工输入、短信挑战及会话保持，再实现 utun 数据通道、授权路由、DNS、断开清理和重连。界面可使用 SwiftUI/AppKit；不依赖原包的 x86_64 核心库。

尚待实际账号联调确认：

- 实际短信挑战类型及验证码失败、过期、重发行为。
- 网页协议和原生客户端 XML 协议之间的会话关系。
- 登录后隧道握手、地址/路由/DNS 分配及真实内网访问。
- 是否存在原客户端专属检查或其他网关策略要求。
- 与用户已有代理/VPN 的路由共存、睡眠唤醒和断线恢复。

账号密码、图片及短信验证码均由用户在本地输入；不要求通过聊天提供。所有可视化交互验收由用户自行执行。

## 可参考项目

- [inode-cli](https://github.com/VocabVictor/inode-cli)：实验性 Rust H3C SSL VPN 实现，项目声明支持 macOS ARM64；本轮未编译或审计其源码。已读文档说明短信等认证流程尚未实现，需要扩展，不能直接当作可用替代品。
- [OpenConnect H3C 草案 MR 397](https://gitlab.com/openconnect/openconnect/-/merge_requests/397)：可参考的协议实现草案；不能据此声称标准 OpenConnect 发行版已支持目标网关。

本轮完成的是安装包与协议可行性调查，尚未产出 ARM 客户端。


后续实现进度：已产出原生 ARM 实验客户端 0.1.0，参见 `iNodeARM/使用说明.md` 和 `iNodeARM/验证记录.md`。真实账号和内网验收仍待用户完成。
