# 落地规则集

两份，**互不重叠**，各绑一个落地：

- **`landing.json`（50 域名 + 148 IP 段）** — 走**日常/主力**落地（速度快的那台）。Google 全家桶都在这里：YouTube 整站、Google 搜索、**Google Play 商店与下载**、Google 账号/静态资源，外加 Gemini。
- **`landing-v2.json`（40 域名）** — 只放对 IP 要求高的 AI：ChatGPT / Claude / Grok / Perplexity / Poe / Character / Copilot，以及 Google 的 NotebookLM / Labs / Jules / Flow / Opal / Antigravity / Stitch / DeepMind。

> `landing.json` 里那 148 条 `ip_cidr` 是 Google 官方前缀（取自 https://www.gstatic.com/ipranges/goog.json ）：Play 取包经常 302 到 **IP 直连**，域名规则接不住，这一组兜住。它只对"目标已经是 IP"的连接生效，不影响普通域名分流。
>
> 两份都没命中的域名 → `route.final = direct`，从中转机自己的 IP 直连（maps / drive / mail 等仍是直连）。

## 一键复制

```
https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing.json
```

```
https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing-v2.json
```

```
https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/warp.json
```

> `rules/warp.json` 是 **WARP 专用**（89 域名 = 上面两份的并集，去掉探针）：只在 `[9] WARP 出站管理 → [2] → [2] 自定义规则` 里用，回车即默认。不要拿它给落地绑，也不要拿 `landing.json` 给 WARP 用（tag 会撞名）。

## 改完怎么一眼看出生效

**landing.json（日常落地）**
```
https://ipinfo.io/json
```
`"ip"` / `"country"` 是落地 IP 和国家 → 生效；显示上海/`CN` → 没命中。

**landing-v2.json（AI 落地）**
```
https://chatgpt.com/cdn-cgi/trace
```
看 `ip=` 和 `loc=`：`loc=AU`（或对应国家）= 生效；`loc=CN` = 没命中。（`https://claude.ai/cdn-cgi/trace` 同理，纯文本、不触发风控。）

配置层面：`[18] → [4] 查看当前中转链路`，落地后面显示 `自定义规则集 (landing)` / `(landing-v2)` 就是绑好了；显示 `全局兜底` 说明没绑规则集。

## 用法

`[18] 进阶转发管理 → [8] 中转分流管理 → [2] 设置落地规则 → [3] 自定义规则集`，粘贴上面的 URL。

同一个文件不要同时给两个落地用（tag 由文件名生成，会撞 `duplicate rule-set tag`）。

## 改动后生效

规则集是运行时按 URL 拉取的：推送后**重启服务**即可（面板 `[6]` 或 `rc-service sing-box restart`），不用重新绑定。确认版本：

```bash
curl -s https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing.json \
  | jq '{域名:(.rules[0].domain_suffix|length),IP段:(.rules[1].ip_cidr|length)}'   # 50 / 148
curl -s https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing-v2.json \
  | jq '{域名:(.rules[0].domain_suffix|length)}'                                   # 40
```

> raw 有几分钟 CDN 缓存，刚推送时可能拉不到新版，等一会儿再重启。

看某条请求实际走哪：

```bash
journalctl -u sing-box -f --no-pager | grep -Ei 'gvt|play\.googleapis|android|1e100|ngstr|googlevideo'
```

`outbound/vless[relay-out-xxxx]` 才是命中，`outbound/direct` 就是没命中。

> 与 WARP 的关系：顺序固定为「落地规则 → WARP 接管 → 其他」。命中规则走对应落地；**没命中的流量，启用了 WARP 就走 WARP**，没启用就按 `route.final=direct` 直连。

## UDP 转发（`[U]`）

中转机如果是 NAT 小鸡、原生 UDP 被禁，`[U]` 可以把 UDP 交给落地（走 TCP 隧道）。开启前请先在落地机确认它**能发 UDP**：

```bash
python3 - <<'EOF'
import socket
q=(b'\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00'
   b'\x03www\x06google\x03com\x00\x00\x01\x00\x01')
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(5)
try:
    s.sendto(q,('1.1.1.1',53)); d,_=s.recvfrom(512); print("UDP OK", len(d))
except Exception as e: print("UDP FAILED:", e)
EOF
```

落地发不出 UDP 时**不要开** `[U]`：DNS 会被送过去解析不出来，表现是所有网站都打不开。

## WARP 专用（`rules/warp.json`，89 域名）

`[9] WARP 出站管理 → [2] 启用接管并设置规则 → [2] 自定义规则` 里**直接回车**就会用这份，
它是 `landing.json` + `landing-v2.json` 的并集（去掉探针域名），所以一处规则同时覆盖：

- YouTube 整站 + YT 音乐、Google 搜索、Google Play（含下载 CDN）
- Gemini 与 Google 其他 AI、主流 AI（OpenAI/Claude/Grok/...）

**为什么要单独一份**：WARP 的自定义规则集 tag 由文件名生成，如果直接用 `rules/landing.json`，
tag 会和落地那份**撞名**（都叫 `landing`），WARP 写入时会覆盖同名的定义、把落地规则改成走
`warp-out` —— 实测会导致落地分流整个消失。现在：

- WARP 默认指向 `rules/warp.json`（tag 是 `warp`，天然不冲突）；
- 即使你手动填了 `landing.json`，只要该 tag 已被非 WARP 规则引用，WARP 会自动改用
  `warp-<tag>` 前缀，并保留原定义不被删除。
