# 落地规则集

两份规则集，按「用得多 / 用得少」分工，**互不重叠**（已用脚本按 `domain_suffix` 包含关系核对），可以同时绑给两个不同落地。

## `landing.json` —— 日常用的那份（建议绑「距离近」的落地）

只放"本体"，不放 Google 账号与静态资源：

- **YT 音乐**：`music.youtube.com`、`youtubei.googleapis.com`、`googlevideo.com`（音视频流）、`ytimg.com`（封面）、`consent.youtube.com`（同意页）
- **Gemini**：`gemini.google(.com)`、`generativelanguage.googleapis.com`、`geminiweb-pa`/`alkalicore-pa`/`alkalimakersuite-pa`、`makersuite`/`bard`/`aistudio`/`ai.studio`、Gemini Code Assist 后端等

> 注意：`googlevideo.com` 是 YT 音乐和普通油管共用的 CDN，所以**普通油管的视频流也走近落地**（但 `www.youtube.com` 页面是直连）。

## `landing-v2.json` —— 不常打开那份（建议绑「大流量」落地）

放三块 + 两个"公共依赖"：

- **主流 AI**：OpenAI/ChatGPT（含 `oaistatic`/`oaiusercontent`/`sora`/`auth0`）、Claude、Grok、Perplexity、Poe、Character.AI、Copilot
- **Google Play 商店**：`play.google.com`、`play.googleapis.com`、`play-fe`、`android.clients.google.com`、`play-lh`、`ggpht.com`（图标），以及 **`gvt1/gvt2/gvt3.com`、`dl.google.com`**（APK 真正的下载 CDN）
- **Google 其他 AI**：NotebookLM、Labs、Jules、Flow、Opal、Antigravity、Stitch、DeepMind
- **公共依赖**：`accounts.google.com`（Google 登录）、`gstatic.com`（JS/CSS/字体）

> 为什么账号和静态资源放 v2 而不是 v1：Play 的授权、checkin、下载如果分属两个出口 IP，会一直卡在「等待中」。把 Google 账号体系与下载放在同一个落地，才不会混源。副作用是 YT 音乐的登录/静态资源也走这条（流量极小，无感）；`gemini.gstatic.com` 也被 `gstatic.com` 覆盖，即 Gemini 的静态资源走这条，只有页面和接口走近落地。

## 用法

`[18] 进阶转发管理 → [8] 中转分流管理 → [2] 设置落地规则 → [3] 自定义规则集`

```
日常落地（听歌/Gemini）→ https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing.json
大流量落地（下载/AI）  → https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing-v2.json
```

规则集 URL 填哪份，那个落地的流量就按哪份走；**同一个文件不要同时给两个落地用**（tag 由文件名生成，会撞 `duplicate rule-set tag`）。

两份都没命中的域名 → `route.final = direct`，从中转机自己的 IP 直连（`www.google.com` 搜索、地图、Drive、Gmail、`www.youtube.com` 页面目前都是直连）。

## 改完怎么生效

规则文件是 sing-box 运行时按 URL 拉取的：推送后 **重启服务**即可（面板 `[6]` 或 `systemctl restart sing-box`），不需要重新绑定。
确认拉到新版可以数条目：`landing.json` = 28 条、`landing-v2.json` = 52 条。

排查分流是否真的命中，看日志里的 outbound：

```bash
journalctl -u sing-box -f --no-pager | grep -Ei 'gvt|play\.googleapis|android\.clients|googlevideo'
```

显示 `outbound/vless[relay-out-xxxx]` 才是命中；显示 `outbound/direct` 就是没命中。

> 与 WARP 的关系：命中规则走对应**落地 VPS**；`[9] WARP 出站管理` 是另一套出口规则，两者并存时落地规则优先，WARP 只接管主节点（未命中分流的入口流量走直连，不会掉进 WARP）。
