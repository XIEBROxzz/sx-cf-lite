# 落地规则集

两份，**互不重叠**，各绑一个落地：

- **`landing.json`（46 域名 + 148 IP 段）** — 日常：YouTube 整站 + Google 搜索 + Google Play（含 APK 下载）+ 登录/静态资源 + Gemini。建议绑**距离近**的落地。
- **`landing-v2.json`（40 域名）** — 只放对 IP 要求高的 AI：ChatGPT / Claude / Grok / Perplexity / Poe / Character / Copilot + NotebookLM / Labs / Jules / Flow / Opal / Antigravity / Stitch / DeepMind。建议绑**AI 解锁**用的落地。

> 为什么不把 Play 拆出去：Play 的授权、checkin、下载 CDN 若分属两个出口 IP，会一直卡在「等待中」。Google 全家桶放同一个落地最稳。
>
> landing.json 里除了域名，还有第二组规则 `ip_cidr`：**Google 官方 IP 段**（取自上 https://www.gstatic.com/ipranges/goog.json ，148 条）。Play 的真实取包经常是 **302 到 IP 直连**，域名规则抓不到，这一组能把它们兜住 —— 所以**不需要开"全局兜底"**，其余流量照旧直连。

## 一键复制

```
https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing.json
```

```
https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing-v2.json
```

## 改完怎么一眼看出生效

**v1（日常落地）** — 浏览器打开：

```
https://ipinfo.io/json
```

`"ip"` 是落地 IP、`"country"` / `"city"` 是落地所在地 → 生效；显示上海/CN → 没命中，退回直连了。

**v2（AI 落地）** — 浏览器打开：

```
https://chatgpt.com/cdn-cgi/trace
```

看 `ip=` 和 `loc=` 两行：`loc=AU`（或对应国家）= 生效；`loc=CN` / 上海 = 没命中。
（`https://claude.ai/cdn-cgi/trace` 同理；都是纯文本，不打开页面、不触发风控。）

配置层面一眼看：`[18] → [8] → [2]` 列表、或 `[4] 查看当前中转链路`，落地后面显示 `自定义规则集 (landing-v2)` 就是绑好了。

## 用法

`[18] 进阶转发管理 → [8] 中转分流管理 → [2] 设置落地规则 → [3] 自定义规则集`，把上面的 URL 粘进去。

同一个文件不要同时给两个落地用（tag 由文件名生成，会撞 `duplicate rule-set tag`）。两份都不命中的域名 → `route.final = direct`，从中转机自己的 IP 直连（`images`/`news`/`translate`/`maps`/`drive`/`mail` 目前仍是直连）。

## 改动后生效

规则集是运行时按 URL 拉取的：推送后**重启服务**即可（面板 `[6]` 或 `systemctl restart sing-box`），不用重新绑定。数条目可确认版本：`landing.json` = 46 域名 + 148 IP 段、`landing-v2.json` = 40 域名。

看某条请求实际走哪：

```bash
journalctl -u sing-box -f --no-pager | grep -Ei 'gvt|play\.googleapis|googlevideo|openai|claude'
```

`outbound/vless[relay-out-xxxx]` 才是命中，`outbound/direct` 就是没命中。

> 与 WARP 的关系：命中规则走对应落地；`[9] WARP 出站管理` 是另一套出口规则，并存时落地规则优先，WARP 只接管主节点。
