# SX-CF-lite

sing-box 一键管理脚本（虫虫版）· 主脚本 **v1.60**

> 基于 [0xdabiaoge/singbox-lite](https://github.com/0xdabiaoge/singbox-lite) 地基 + Joey [xray-cf-lite](https://github.com/byJoey/xray-cf-lite) 的 CF 套皮整合魔改。

## 一键安装
Alpine 前置
```bash
apk update && apk add curl wget net-tools procps bash
```

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/install.sh)
```

安装后 `sx` 进主菜单（等价 `bash /usr/local/etc/sx-cf-lite/singbox.sh`）。

**快捷命令**：`sx` 主菜单 · `s` CF-B 直达 · `x` CF-A 直达

## 一键申请证书（更多协议 → [6]）

需要域名已经托管在 Cloudflare。脚本用 `acme.sh` + Cloudflare DNS-01 申请 Let's Encrypt 证书，自动加解析、下载到本地并每天自动续期。

**准备 Cloudflare 凭据（二选一）**

- **API Token（推荐）**：权限 `Zone:Zone:Read` + `Zone:DNS:Edit`
- **Global API Key**：填 Key 即可（邮箱沿用申请时输入的邮箱）

**操作流程**

1. 主菜单 → `[4] 更多协议` → `[6] 一键申请证书`
2. 输入邮箱、Cloudflare 凭据、子域名（如 `node.example.com`）
3. 脚本自动写入 A/AAAA 解析（强制 **DNS only**，关闭小黄云，避免源站证书被 CF 代理掩盖）
4. 通过 DNS-01 申请证书并下载到本地：
   - `/usr/local/etc/sing-box/certs/<域名>.pem`
   - `/usr/local/etc/sing-box/certs/<域名>.key`
5. 自动启用续期：每天 03:17 执行 `acme.sh --cron`，续期后由 `cert-reload.sh` 重启 sing-box

**创建节点时使用已申请证书**

在 `[4] 更多协议` 里创建 VLESS-WS-TLS / Trojan-WS-TLS / AnyTLS / HY2 / TUIC / gRPC 等需要证书的节点时，脚本会显示：

```
[1] 自动自签 (默认)
[2] 使用已申请证书 (Let's Encrypt, 自动续期)
```

选择 `[2]` 后自动带出证书和域名，节点 SNI 使用证书域名，客户端不再需要跳过证书验证。没有已申请证书时仍默认自签，不影响原有流程。

**证书管理（更多协议 → [7]）**

- `[1]` 申请新证书
- `[2]` 立即检查 / 续期全部
- `[3]` 删除本地证书（仍被节点引用时会拒绝；Cloudflare 上的 DNS 记录需自行删除）

**注意**

- 本证书是**源站证书**，对应解析必须保持 DNS only；如需 CDN 回源请继续用主菜单 `[2] 一键套CF`。
- 卸载脚本时会清理 acme.sh 续期任务和本地证书，但**不会删除 Cloudflare DNS 记录**。
