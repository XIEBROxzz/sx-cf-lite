# 落地规则集

两份，**互不重叠**，各绑一个落地：

- **`landing.json`（34 域名）** — 走**距离近**的落地。YouTube 整站、Google 搜索、Gemini，以及一个探针域名 `ipinfo.io`。
- **`landing-v2.json`（55 域名 + 148 IP 段）** — 走**下载/AI 落地**。ChatGPT / Claude / Grok / Perplexity / Poe / Character / Copilot + NotebookLM / Labs / Jules / Flow / Opal / Antigravity / Stitch / DeepMind，再加 **Google Play 全套**（`play.*`、`android.clients.google.com`、`gvt1/2/3.com`、`dl.google.com`、`ggpht.com`、`android.googleapis.com`、`1e100.net`、`xn--ngstr-lra8j.com`）与 `accounts.google.com`、`gstatic.com`。

> 为什么 Play 跟 v2 走：Play 的授权、checkin、下载 CDN 必须**同一个出口 IP**，否则会卡在「等待中/空转」。域名之外还带一组 `ip_cidr`（Google 官方 148 条前缀，取自 https://www.gstatic.com/ipranges/goog.json ），因为取包经常 302 到 **IP 直连**，域名规则抓不到。
>
> 两份都保留「未命中 → `route.final = direct`」的行为，也就是说**不需要开全局兜底**，其余流量照旧直连。

## 一键复制

```
https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing.json
```

```
https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing-v2.json
```

## 改完怎么一眼看出生效

**v1（近节点）** — 浏览器打开：

```
https://ipinfo.io/json
```

`"ip"` 是落地 IP、`"country"`/`"city"` 是落地所在地 → 生效；显示上海/`CN` → 没命中。

**v2（下载/AI 落地）** — 浏览器打开：

```
https://chatgpt.com/cdn-cgi/trace
```

看 `ip=` 和 `loc=`：`loc=AU`（或对应国家）= 生效；`loc=CN`/上海 = 没命中。（`https://claude.ai/cdn-cgi/trace` 同理，都是纯文本、不触发风控。）

配置层面：`[18] → [8] → [2]` 列表、或 `[4] 查看当前中转链路`，落地后面显示 `自定义规则集 (landing-v2)` 就是绑好了。

## 用法

`[18] 进阶转发管理 → [8] 中转分流管理 → [2] 设置落地规则 → [3] 自定义规则集`，把上面的 URL 粘进去。

同一个文件不要同时给两个落地用（tag 由文件名生成，会撞 `duplicate rule-set tag`）。两份都不命中的域名 → 从中转机自己的 IP 直连（`images`/`news`/`translate`/`maps`/`drive`/`mail` 等）。

## 改动后生效

规则集是运行时按 URL 拉取的：推送后**重启服务**即可（面板 `[6]` 或 `systemctl restart sing-box`），不用重新绑定。确认版本：

```bash
curl -s https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing.json \
  | jq '{域名:(.rules[0].domain_suffix|length)}'          # 34
curl -s https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing-v2.json \
  | jq '{域名:(.rules[0].domain_suffix|length), IP段:(.rules[1].ip_cidr|length)}'   # 55 / 148
```

> raw 有几分钟 CDN 缓存，刚推送时可能还是旧版，等一会儿再重启。

看某条请求实际走哪：

```bash
journalctl -u sing-box -f --no-pager | grep -Ei 'gvt|play\.googleapis|android\.clients|googlevideo|openai'
```

`outbound/vless[relay-out-xxxx]` 才是命中，`outbound/direct` 就是没命中。

> 与 WARP 的关系：命中规则走对应落地；`[9] WARP 出站管理` 是另一套出口规则，并存时落地规则优先，WARP 只接管主节点。
