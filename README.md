# Cloudflare Tunnel 管理面板

Cloudflare Worker部署的Argo tunnel网页管理面板，用于管理多账户下的 Argo Tunnel：新建/编辑/删除隧道、查看连接 Token、增删域名路由、查看在线状态，并可选地把隧道上线/离线事件通过 Telegram 推送提醒。

**新增：域名资产管理（顶栏 📂）**：点击域名查看旗下子域名；点击子域名可查看其关联的 **DNS 解析记录、Origin Rules 规则、Origin 证书、隧道**，支持单个删除或一键清理全部关联资源。

整个项目只有 **一个文件**：`_worker.js`（Worker 代码 + 内嵌管理页面，无需构建、无外部依赖）。

## 部署只需 4 个变量（邮箱 + API Key 简化版）

| 变量 | 必填 | 说明 |
| --- | --- | --- |
| `EMAIL` | ✅ | Cloudflare 登录邮箱 |
| `API_KEY` | ✅ | **Global API Key**（My Profile → API Keys → Global API Key）。全权限，无需再创建/配置 API Token 权限 |
| `CF_ACCOUNT_ID` | ✅ | Cloudflare 账户 ID（任一域名的 Overview 页右侧可见） |
| `PASSWORD` | ✅ | 面板登录密码，至少 6 位 |

可选：`SESSION_SECRET`（会话密钥）、`DEFAULT_SERVICE`（默认本地服务）、`TG_BOT_TOKEN` / `TG_CHAT_ID`（Telegram 提醒）。

> 旧版 `CF_API_TOKEN`（API Token）方式仍兼容：未配置 `EMAIL` + `API_KEY` 时自动回落到 Token 认证。

### 部署步骤

1. Dashboard → **Workers & Pages** → **Create** → 创建 Worker，把 `_worker.js` 内容全部粘贴进去，保存。
2. Settings → Variables and Secrets 添加上表 4 个变量。
3. （可选）多账号 / Telegram 提醒需要存储：绑定 D1（变量名 `TUNNEL_DB`，推荐）或 KV（变量名 `TUNNEL_STATE`）。
4. 打开 `https://<Worker 域名>`，输入密码登录即可。

## 功能一览

- **密码登录**：访问面板需输入密码，会话 Cookie 签名有效期 7 天，登录接口有防爆破延时。
- **邮箱 + API Key 一把梭**：Global API Key 全权限，DNS / Origin Rules / Origin 证书 / 隧道均可管理，告别配一堆 Token 权限。
- **域名资产管理**：域名 → 子域名 → 关联资源（DNS 解析、Origin Rules、Origin 证书、隧道路由/整条隧道）的树式视图，可逐项删除，也可一键清理某个子域名的全部关联资源。
- **多账号管理**：可添加多个 Cloudflare 账号（各自 API Token，验证后存 D1）并切换；环境变量配置的账号作为默认账号。
- **隧道管理**：列表展示所有隧道及状态（在线/降级/离线/未启用 + 运行时长）、搜索过滤、查看启动 Token、修改名称与本地服务地址、删除隧道。
- **新建隧道**：选择域名 (Zone)、子域名、可选路径、本地服务地址，自动创建隧道并自动配置 DNS CNAME 记录。
- **多路由管理**：在已有隧道上增删"域名 + 路径 → 服务"的 ingress 规则（每条隧道最多 60 条），自动处理 DNS，冲突时拒绝写入。
- **Telegram 上下线提醒**：状态**发生变化**才推送，可按隧道逐个开关（默认关闭）；支持多个接收者、暂停/恢复推送。
- **PWA**：可安装到桌面/手机主屏。

## 存储：D1（推荐）或 KV

KV 有每日写入次数限制且存在最终一致延迟，推荐 D1：

1. Dashboard → Storage & Databases → D1 → Create，建库（名称随意，如 `tunnel-state`）；
2. 控制台执行：`CREATE TABLE IF NOT EXISTS state (k TEXT PRIMARY KEY, v TEXT NOT NULL);`
3. Worker → Settings → Bindings → D1 Database，变量名填 **`TUNNEL_DB`**；
4. 重新部署。未绑定 D1 时自动回退到 KV (`TUNNEL_STATE`)。

## 多账号管理

- 用 `EMAIL` + `API_KEY`（或 `CF_API_TOKEN`）+ `CF_ACCOUNT_ID` 配置的账号永远存在，名为"默认账号"，不可删除。
- 顶栏下拉选择账号，切换后隧道列表、域名、路由、提醒开关随账号切换。
- 点击右上角**账号管理**：填名称、账户 ID 与该账户的 API Token，**先验证再保存**（Token 只存 D1，不回显）。
- 未绑定 KV/D1 时多账号功能不可用，回退为默认单账号。

## Telegram 提醒配置

1. 用 [@BotFather](https://t.me/BotFather) `/newbot` 创建机器人，拿到 **Bot Token**。
2. 接收者先给机器人发一条消息（或 `/start`），否则机器人无法主动私聊。
3. chat_id：个人填正数用户 ID（问 [@userinfobot](https://t.me/userinfobot)）；群组填负数 ID；公开频道/群组可填 `@用户名`。
4. 面板 → **Telegram 配置**：填 chat_id 和 Bot Token，"测试发送"确认，再"保存"。
5. Tunnel 管理 → 把需要的隧道"🔕 提醒关"点成"🔔 提醒开"。

## API 接口概览

除 `/api/login` 外，所有接口需登录（Cookie 会话）。均为 `POST` + JSON：

| 路径 | 说明 |
| --- | --- |
| `/api/login` `/api/logout` | 登录 / 退出 |
| `/api/init` | 域名 (Zone) 列表、默认服务地址 |
| `/api/list` | 隧道列表 + 在线状态 + 提醒状态（同时触发一次检查） |
| `/api/create` `/api/update` `/api/delete` | 新建 / 编辑 / 删除隧道 |
| `/api/token` | 获取隧道启动 Token（cloudflared 用） |
| `/api/uptime` | 连接器运行时长 |
| `/api/detail` `/api/route` | 查看 / 增删隧道 ingress 路由 |
| `/api/assets` `/api/asset` | 域名资产树：域名 → 子域名 → 关联资源 |
| `/api/assetOp` | 资产操作：删 DNS 记录 / Origin 规则 / Origin 证书 / 隧道路由 / 整条隧道 / 一键清理 |
| `/api/alert` | 隧道提醒开关 (toggle) / 吞掉一次变化 (skip) |
| `/api/tg` | Telegram 配置：保存、测试、增删接收者、暂停/恢复 |
| `/api/acc` | 多账号：列表 / 添加 / 删除 / 切换 |

## 常见问题

- **Global API Key 在哪**：My Profile → API Keys → Global API Key → View（与登录密码不同）。
- **资产管理里删除不了 Origin 规则/证书**：Global API Key 理论上全权限；若仍报错多为规则集结构特殊，请到 Dashboard 手动检查该规则集。
- **一键清理会删掉共用证书吗**：不会。若一张 Origin 证书覆盖多个不同主机名，为避免误伤会跳过删除，其余情况按主机名匹配删除。
- **"未绑定 KV 命名空间 TUNNEL_STATE"**：绑定 D1（`TUNNEL_DB`，推荐）或 KV（`TUNNEL_STATE`）。
- **"隧道仍有活跃连接,请先停止 cloudflared"**：删除前需先在目标机器停止 `cloudflared`（Cloudflare 平台限制）。
- **改密码后所有人掉线**：未设置 `SESSION_SECRET` 时会话密钥由密码派生；设置独立的 `SESSION_SECRET` 可避免。

## 安全说明

- 所有 Cloudflare API 调用都在 Worker 服务端完成，EMAIL / API_KEY / Token 不会下发到浏览器。
- 隧道启动 Token 仅在登录后按需单独获取。
- 登录密码比较使用固定时间算法；连续失败有延时惩罚。
- 建议设置 `SESSION_SECRET`，可选给 Worker 域名加上 Cloudflare Access 做第二层防护。
