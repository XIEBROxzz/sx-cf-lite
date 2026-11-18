# SX-CF-lite

sing-box 一键管理脚本（虫虫版）· 主脚本 **v1.79.10**（[16] → [K] 内核网络调优：FQ+BBR / 内存自适应缓冲 / UDP 队列，三组独立开关；缓冲按内存档位直设，另可 `[6]` 手动指定上限）

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
