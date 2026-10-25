# 落地规则集

两份规则集，**互不重叠**（已用脚本按 `domain_suffix` 包含关系核对），一份走「近节点」管日常，一份走「高 IP 要求」的节点管 AI。

## `landing.json` —— 日常那份（建议绑**距离近**的落地）

Google 全家桶（除 AI 以外的常用部分）+ YT：

- **YouTube 整站**：`youtube.com`、`youtu.be`、`youtube-nocookie.com`、`music.youtube.com`、`youtubei.googleapis.com`、`googlevideo.com`、`ytimg.com`、`consent.youtube.com`
- **Google 搜索**：`www.google.com`、`google.com.hk`
- **Google Play 商店 + 下载**：`play.google.com`、`play.googleapis.com`、`play-fe`、`android.clients.google.com`、`play-lh`、`ggpht.com`，以及 **`gvt1/gvt2/gvt3.com`、`dl.google.com`**（APK 真正的下载 CDN）
- **Google 公共依赖**：`accounts.google.com`（登录）、`gstatic.com`（JS/CSS/字体）
- **Gemini**：`gemini.google(.com)`、`generativelanguage.googleapis.com`、`geminiweb-pa`/`alkalicore-pa`、`makersuite`/`bard`/`aistudio`/`ai.studio`、Gemini Code Assist 后端等

> 为什么不拆 Play 到另一条：Play 的授权、checkin、下载 CDN 如果分属两个出口 IP，会一直卡在「等待中」。Google 全家桶放同一个落地最稳。

## `landing-v2.json` —— 只在需要时用（建议绑 **AI 解锁/住宅 IP** 那种落地）

只放对 IP 要求高的 AI，不含任何 Google 日常域名：

- **主流 AI**：OpenAI/ChatGPT（`openai.com`/`chatgpt.com`/`oaistatic`/`oaiusercontent`/`sora`/`auth0`）、Claude、Grok、Perplexity、Poe、Character.AI、Copilot
- **Google 其他 AI 产品**：NotebookLM、Labs、Jules、Flow、Opal、Antigravity、Stitch、DeepMind

## 怎么一眼看出 v2 生效

不用真的去用 AI —— 打开一个纯文本探针即可：

```
https://chatgpt.com/cdn-cgi/trace
```

看返回里的两行：

- `ip=` 是悉尼/该落地的 IP、`loc=AU`（或对应国家）→ **v2 生效**
- `ip=` 是上海、`loc=CN` → **没生效**，请求退回直连了

`https://claude.ai/cdn-cgi/trace` 同理（Claude 也在 Cloudflare 后面）。

配置层面一眼看：`[18] → [8] → [2]` 列表、或 `[4] 查看当前中转链路`，该落地显示 `自定义规则集 (landing-v2)` 就是绑定好了。

## 用法

`[18] 进阶转发管理 → [8] 中转分流管理 → [2] 设置落地规则 → [3] 自定义规则集`

```
日常落地（Google/YT/Gemini/Play）→ .../rules/landing.json
AI 落地（高 IP 要求）            → .../rules/landing-v2.json
```

同一个文件不要同时给两个落地用（tag 由文件名生成，会撞 `duplicate rule-set tag`）。两份都不命中的域名 → `route.final = direct`，从中转机自己的 IP 直连（`images`/`news`/`translate`/`maps`/`drive`/`mail` 等目前仍是直连）。

## 改完怎么生效

规则文件是 sing-box 运行时按 URL 拉取的：推送后**重启服务**即可（面板 `[6]` 或 `systemctl restart sing-box`），不必重新绑定。
确认拉到新版可以数条目：`landing.json` = 45 条、`landing-v2.json` = 40 条。

看某条请求实际走哪：

```bash
journalctl -u sing-box -f --no-pager | grep -Ei 'gvt|play\.googleapis|googlevideo|openai|claude'
```

显示 `outbound/vless[relay-out-xxxx]` 才是命中，`outbound/direct` 就是没命中。

> 与 WARP 的关系：命中规则走对应**落地 VPS**；`[9] WARP 出站管理` 是另一套出口规则，并存时落地规则优先，WARP 只接管主节点。
