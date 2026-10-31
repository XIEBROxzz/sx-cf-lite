# SX-CF-lite

sing-box 一键管理脚本（虫虫版）· 主脚本 **v1.67**

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

**准备 Cloudflare 凭据（三选一）**

- **复用已保存凭据**：CF-A（`[3]` 套 CF）或 CF-B（`[4]` Argo 隧道）输入过 Global API Key 后，这里直接选 `[3]`，邮箱和 Key 都不用再敲
- **API Token（推荐）**：权限 `Zone:Zone:Read` + `Zone:DNS:Edit`
- **Global API Key**：填 Key 即可（邮箱沿用上面输入的邮箱）

**操作流程**

1. 主菜单 → `[4] 更多协议` → `[6] 一键申请证书`
2. 输入 Cloudflare 邮箱、凭据与子域名（如 `node.example.com`）
3. 脚本自动写入 A/AAAA 解析（强制 **DNS only**，关闭小黄云，避免源站证书被 CF 代理掩盖）
4. 通过 DNS-01 申请证书并下载到本地：
   - `/usr/local/etc/sing-box/certs/<域名>.pem`
   - `/usr/local/etc/sing-box/certs/<域名>.key`
5. 自动启用续期：每天 03:17 执行 `acme.sh --cron`，续期后由 `cert-reload.sh` 重启 sing-box

> **这个邮箱就是 Cloudflare 账号邮箱**（同一邮箱兼作 Let's Encrypt 通知），提示里已明确标注，不再写成容易误解的「Let's Encrypt 通知用」。

> **三处凭据双向互通**：CF-A 存 `/etc/sing-box-cf-lite/cf_account.json`，CF-B 存 `/usr/local/etc/sing-box/cf_account.json`（旧版 `/etc/xray-cf-lite/`），字段一致（`email` + `api_key`）。CF-A 与 CF-B 本来就双向互读；证书流程也接入了同一批文件：
>
> - **读**：任一处存过 Global API Key，证书里选 `[3]` 直接复用，邮箱也会带出默认值；
> - **写**：证书里手动输入的 Global API Key 验签通过后回写两处 `cf_account.json`（保留 `account_id` 等字段），之后套 CF / Argo 隧道不用再输入。
>
> 回写有账号隔离：目标文件的 `email` 与本次输入不一致时**不覆盖**，只提示跳过，避免把另一个 CF 账号的 Key 写进去。API Token 不回写（`cf_account.json` 只存 Global API Key）。

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
- **删除节点不会清理证书和凭据**：已申请证书（`certs/<域名>.pem|.key`）、`managed.json` 索引、Cloudflare 邮箱/Key、云端解析都原样保留，可直接给新节点复用。只有每个节点专属的自签证书（`<tag>.pem`）会随节点删除，下次创建会自动重建。
- **CF-A / CF-B 节点同理**：删节点会清掉该节点的云端 DNS、Origin Rules、Origin 证书 / Argo 隧道，但 `cf_account.json`（邮箱 + API Key）**保留**，删完再建节点不用重新输入。Argo 卸载（`s` 菜单 `[7]`）也不再删这份共用凭据。
- **卸载脚本才做一次性清理**：云端解析 → 本地证书/私钥 → acme.sh 续期记录（含 acme.sh 自带的 cron 行）→ `~/.acme.sh/account.conf` 里明文保存的 CF 凭据 → `cf_account.json`。云端只删仍指向本机的记录；记录已被改到别的机器时会逐条询问，避免拆掉别处的解析。

## 本机 IP 与地址族（入口 / 出站）

主菜单、`[14] DNS 设置`、`[16] 进阶转发管理` 头部都会显示一行本机地址：

```
本机 IP: IPv4 1.2.3.4   IPv6 2400:3200:baba::1
```

读的是网卡全局地址（`ip -4/-6 addr show scope global`），瞬时完成、不发网络请求，所以菜单每帧刷新也不会卡。哪一族没有就显示「无」；NAT 小鸡网卡上只有私网地址时会标注 `(内网)`，避免误以为公网 IP 变了。

**三个开关的分工**（`[14]` 一个全局，`[16]` 两个方向）：

| 开关 | 配置文件字段 | 作用 | 影响范围 |
|---|---|---|---|
| `[14] → [7]` 域名解析策略 | `.dns.strategy` + `.route.default_domain_resolver.strategy` | DNS 模块的**默认**策略（兜底） | 全部流量，含走落地/WARP 的域名解析 |
| `[16] → [B] → [1]~[5]` 直连地址族 | `.outbounds[direct].domain_resolver.strategy` | 直连**出站拨号**用哪一族 | 只有直连流量 |
| `[16] → [B] → [6]/[7]` 节点地址探测 | `node_ip_pref`（状态文件） | 创建节点时**默认填哪个 IP** | 只影响地址探测顺序 |

要点：

- **出站级覆盖全局**。`[B]` 选 `prefer_ipv6` 时，直连拨号会带着自己的策略去查，盖掉 `[14][7]` 的全局默认；所以「只想让直连走 v6」用 `[B]`，「全站都不想碰 v6」才用 `[14][7]`。两个都设成 v6 时 `[B]` 等于白设。
- **别用 `[14][7]` 治送中**。它会把走落地/WARP 的域名解析也一起改成 v6，落地机如果只有 A 记录，整条链路直接断流。
- **节点地址与 DNS 策略无关**。`默认 IP` 来自 `_get_public_ip()` 的 `curl` 探测（走宿主网络，不经 sing-box），以前硬编码 v4 优先，所以设了 v6 优先也还是 v4。现在按 `[16] → [B] → [6]/[7]` 的偏好先探测对应族，拿不到自动回退另一族；默认仍是 v4 优先，行为不变。
- 节点地址偏好存在 `/usr/local/etc/sing-box/node_ip_pref`（`ipv4` / `ipv6`），只影响**之后新创建**的节点；本次运行已缓存的地址需重开脚本才生效。卸载脚本时随目录一并清理。
