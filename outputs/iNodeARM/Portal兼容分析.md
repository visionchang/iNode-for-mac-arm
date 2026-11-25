# Portal 密码编码对照（0.4.4）

本次只分析安装包及纯运算函数，不启动 Windows 安装程序、原版客户端或图形界面，不使用真实凭据。

## 参考对象

| 对象 | 密码运算 | 对照结果 |
|---|---|---|
| 本机 Mac E0641，`/usr/local/lib/libiNodeUtility.dylib` | 32 位溢出、带符号右移、16 轮 | 与 Windows E0598 相同 |
| 用户提供的 Windows E0598，`Common/inode_utility.dll` | 32 位溢出、带符号右移、16 轮 | 三组虚拟输入均与 Mac E0641 一致 |
| 用户提供的 Mac E0653 | 对应函数使用 64 位中间运算 | 输出不同，0.4.1—0.4.3 误以它作为密码兼容依据 |

Windows 包外层为 iNode 自定义封装。静态还原后提取 `iNodeClient.7z`，只读取 Portal 与公共库组件。`Portal/iNodePortal.exe` 的密码编码调用导入 `utl_EncryptHashKey`，固定兼容 key 的四个字与本机 Mac 一致。该 key 是公开协议常量，不是账号密码或 TLS 证书。

Windows `Common/inode_utility.dll` 的导出函数 RVA `0xB3FC0` 调用纯运算函数 RVA `0xB3D90`，其中右移指令为 SAR；在离线 x86 模拟器内对纯函数进行编码及解码回环。Mac E0641 的纯函数地址为 `0x9CC6`，在本机离线参考程序中执行。两者的以下结果逐字节一致：

| 虚拟输入 | 输入区长度 | 输出十六进制 |
|---|---:|---|
| `test&password` | 补零至 32 字节 | `8506da662c4c8355825db6f1d6426d8ed2b3265832d34baad2b3265832d34baa` |
| `local-test-password` | 补零至 32 字节 | `cc6050ab719ffd4a1872d43eca8b5c346b95cdb10cf998dad2b3265832d34baa` |
| `12345678901234567890123456789012` | 32 字节 | `43b2a3436170eea07ae9351552b3f1d01ce9777707cec4a6eb2646ab4c5c1ea4` |

这里比较的是相同 32 字节输入区的底层编码运算。Windows 完整调用也支持按实际长度向 8 字节对齐；ARM 保留本机 Mac 正常账号密码路径的 32 字节输入区，未据此更改长度策略。新 Rust 实现使用上述独立原版输出作为回归数据，不再以自身编码函数生成期望值。

## 参考二进制 SHA-256

- Mac E0641 Utility：`b1f56e23348fb226308ae065ed7fb4726b0271260177e331ec729273540e5057`
- Windows E0598 Utility：`62213402733b257ee154c8aa6386dc1e918499ee9a9c5d6a296038dec466d959`
- Windows E0598 Portal：`f570e164776a9098d752b9d381c12324636a8b02300d2c78b822f70ab5701ac5`

以上证明密码运算差异已修复，真实服务器登录结果仍须用户验证。报文校验、来源检查、固定 VPN 证书和不自动重试策略保持不变。
