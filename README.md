# SX-CF-lite

sing-box 一键管理脚本（虫虫版）· 主脚本 **v1.13**

> 基于 [0xdabiaoge/singbox-lite](https://github.com/0xdabiaoge/singbox-lite) 地基 + Joey [xray-cf-lite](https://github.com/byJoey/xray-cf-lite) 的 CF 套皮整合魔改。

## 能做什么

- **CF-B**：Argo 隧道（临时 / 固定域名）
- **CF-A**：橙云 VLESS-WSS + OriginRules（入站并入主 sing-box）
- **中转落地**：Token / 分享链接导入落地，按规则集分流（Play、YouTube、Gemini、主流 AI）
- **出口优化**：WARP 出站 · UDP 转发 · IPv4/IPv6 优先
- **端口转发**、定时重启、脚本/规则集在线更新

## 一键安装

```bash
# Alpine 前置
apk update && apk add curl wget net-tools procps bash
```

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/install.sh)
```

安装后 `sx` 进主菜单（等价 `bash /usr/local/etc/sx-cf-lite/singbox.sh`）。

**快捷命令**：`sx` 主菜单 · `s` CF-B 直达 · `x` CF-A 直达

## 主菜单

| 键 | 功能 | 键 | 功能 |
|---|---|---|---|
| 1 | 创建直连节点 | 2 | 一键套 CF |
| 3 | 查看节点链接 | 4 | 删除节点 |
| 5 | 修改节点配置 | 6 / 7 | 重启 / 停止服务 |
| 8 | 查看运行状态 | 9 | 实时日志 |
| 10 | 定时重启 | 11 | 时间诊断 / 校时 |
| 12 | 检查配置 | 13 | 更新脚本 |
| 14 | DNS 设置 | 15 | 安装/更新内核 |
| 16 | 进阶转发 | 17 | CF 节点优选订阅 |
| 18 | 卸载脚本 | 0 | 退出 |

## 进阶转发（16）

| 键 | 功能 |
|---|---|
| 1 / 2 / 3 | 落地机生成 Token / 中转机 Token 导入 / 导入第三方节点 |
| 4 / 5 / 6 / 7 | 查看链路 / 删除落地 / 解除入口对接 / 改入口端口 |
| 8 | 中转分流管理 |
| R | 清空所有中转配置 |
| 9 | WARP 出站管理 |
| U | UDP 转发（NAT 小鸡禁 UDP 时，把 DNS/QUIC 交给落地） |
| V | IPv4/IPv6 优先（作用于全部落地） |
| 10 | 端口转发管理 |

落地规则集见 [rules/README.md](rules/README.md)：`landing.json`（Google 全家桶 + Gemini）、`landing-v2.json`（高 IP 要求的 AI）。

## 更新

菜单 `[13]` 一键更新全部脚本组件（事务式替换，任一失败整组回滚）。
