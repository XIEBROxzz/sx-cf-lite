# 默认落地规则集

## 用法
在 sx / 一键安装 → 创建中转时，[18] 转发模式选 **[3] 自定义规则集URL分流**，直接 **回车**，即使用本规则集。
命中规则的所有域名流量走**落地 VPS**，未命中走中转机直连兜底。 [9] WARP 出站管理，自定义规则同理。
```规则集 URL：
https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/rules/landing.json
```
