# 落地规则集

两份规则集，按「用得多 / 用得少」分工，互不重叠（已验证无域名冲突），可以同时给两个不同落地用。

## `landing.json` —— 日常用的那份（建议绑「距离近」的落地）

管两件事：

- **YT 音乐**：`music.youtube.com`、`youtubei.googleapis.com`、`googlevideo.com`（音视频流）、`ytimg.com`（封面）
- **Gemini**：`gemini.google(.com)`、`gemini.gstatic.com`、`generativelanguage.googleapis.com`、`makersuite`/`bard`/`aistudio`/`ai.studio`、Gemini Code Assist 后端等

外加三条**依赖**（不加会「能打开但播放/登录报错」）：`consent.youtube.com`（同意页）、`accounts.google.com`（登录）、`gstatic.com`（JS/CSS/字体）。

> 注意：`accounts.google.com` 和 `gstatic.com` 是 Google 全家桶级别 —— 所有 Google 登录、所有 Google 站点的静态资源都会走近落地，不只音乐和 Gemini。`googlevideo.com` 也是共用的，因此**普通油管的视频流同样走近落地**（但 `www.youtube.com` 页面仍是直连）。

## `landing-v2.json` —— 不常打开那份（建议绑「大流量」落地）

管三块：

- **主流 AI**：OpenAI/ChatGPT（含 `oaistatic`/`oaiusercontent`/`sora`/`auth0`）、Claude、Grok、Perplexity、Poe、Character.AI、Copilot
- **Google Play 商店**：`play.google.com`、`play.googleapis.com`、`play-fe`、`android.clients.google.com`、`play-lh`（图标），以及 **`gvt1/gvt2/gvt3.com`、`dl.google.com`**（APK 真正的下载 CDN，少了这几条会「商店能开、点安装卡住」）
- **Google 其他 AI 产品**：NotebookLM、Labs、Jules、Flow、Opal、Antigravity、Stitch、DeepMind

## 用法

`[18] 进阶转发管理 → [8] 中转分流管理 → [2] 设置落地规则 → [3] 自定义规则集`

```
日常落地（听歌/Gemini）→ https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing.json
大流量落地（下载/AI）  → https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing-v2.json
```

规则集 URL 里填哪份，那个落地的流量就按哪份走；**同一个文件不要同时给两个落地用**（规则集 tag 由文件名生成，会撞 `duplicate rule-set tag`）。

两份都没命中的域名 → `route.final = direct`，从中转机自己的 IP 直连（`www.google.com` 搜索、地图、Gmail、普通油管页面目前都是直连）。

## 改完怎么生效

规则文件是 sing-box 运行时按 URL 拉取的：改完推送后 **重启服务**即可（面板 `[6]` 或 `systemctl restart sing-box`），不需要重新绑定。
想确认拉到的是新版，数条目数即可：`landing.json` = 31 条、`landing-v2.json` = 49 条。

> 与 WARP 的关系：命中规则走对应**落地 VPS**；`[9] WARP 出站管理` 是另一套出口规则，两者并存时落地规则优先，WARP 只接管主节点（未命中分流的入口流量走直连，不会掉进 WARP）。
