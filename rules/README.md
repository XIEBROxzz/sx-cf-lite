# 落地规则集

## 分工
- **`rules/landing.json`** — YT Music + Gemini (含 NotebookLM/Jules/Labs/Flow/AI Studio 等谷歌 AI 系) + 谷歌 Play 商店
- **`rules/landing-v2.json`** — 剩余主流 AI: OpenAI/ChatGPT、Claude、Grok、Perplexity、Poe、Character.AI、Copilot

## 用法
在 中转菜单 → **[R] 中转分流管理 → [2] 设置落地规则 → [3] 自定义规则集 URL**，每个落地单独选择：

```规则集 URL：
https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing.json
```

```规则集 URL：
https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing-v2.json
```

- 想某个落地专门接管 YT Music/Gemini/Play → 该落地用 `landing.json`
- 想某个落地专门解锁剩余 AI → 该落地用 `landing-v2.json`
- 同一入口多落地时，各落地按需各用一份，未命中走中转机直连兜底 (`route.final = direct`)

> 命中规则的所有域名流量走对应**落地 VPS**。[W] WARP 出站管理，自定义规则同理。
