#!/bin/sh
# ─────────────────────────────────────────────────────
#  SX-CF-lite 一键安装器
#  五件套落位 + sx 快捷命令 (指向主脚本, 自更新沿符号链接写回原位)
#  用法: bash install.sh            (从 GitHub 下载)
#        bash install.sh --local <dir>  (从本地目录安装, 测试用)
#  地基: /usr/local/etc/sx-cf-lite/{singbox,advanced_relay,parser,cf_lite,singbox-lite_tunnel}.sh
#        + /usr/local/bin/{sx,s} 快捷命令; rules/landing.json 供 [18] 落地规则集在线引用
# ─────────────────────────────────────────────────────
set -u

BASE="https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main"
DEST="/usr/local/etc/sx-cf-lite"
BIN_LINK="/usr/local/bin/sx"
FILES="singbox.sh advanced_relay.sh parser.sh cf_lite.sh singbox-lite_tunnel.sh"

[ "$(id -u)" = "0" ] || { echo "请用 root 运行: bash install.sh"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "缺少 curl, 请先安装 (apt/yum/apk install curl)"; exit 1; }

mkdir -p "$DEST"

if [ "${1:-}" = "--local" ] && [ -d "${2:-}" ]; then
    echo "本地安装模式: 从 $2 复制五件套"
    for f in $FILES; do
        [ -f "$2/$f" ] || { echo "缺少 $f"; exit 1; }
        cp -f "$2/$f" "$DEST/$f" || exit 1
    done
else
    for f in $FILES; do
        echo "下载 $f ..."
        curl -fsSL "$BASE/$f" -o "$DEST/$f" || { echo "下载失败: $f (检查网络或确认仓库已推送)"; exit 1; }
    done
fi
chmod +x "$DEST"/*.sh
ln -sf "$DEST/singbox.sh" "$BIN_LINK"
# SX: s = CF-B Argo 隧道直达 (与 x 同款拉取壳: 每次执行拉仓库最新版; 网络不通回退本地副本)
# 先摘除旧软链, 防止追加时的 cat> 顺着软链写坏目标脚本
rm -f /usr/local/bin/s
cat > /usr/local/bin/s << 'SCEOF'
#!/bin/sh
tmp=$(mktemp /tmp/sb-argo.xXXXXXX) 2>/dev/null
if [ -n "$tmp" ] && curl -fsSL https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/singbox-lite_tunnel.sh -o "$tmp" 2>/dev/null; then
    trap 'rm -f "$tmp"' EXIT
    bash "$tmp" "$@"
else
    echo "[注意] 网络拉取失败, 使用本地副本" >&2
    exec bash /usr/local/etc/sx-cf-lite/singbox-lite_tunnel.sh "$@"
fi
SCEOF
chmod +x /usr/local/bin/s
echo ""
echo "  ✓ SX-CF-lite 安装完成"
echo "  组件目录: $DEST"
echo "  快捷命令: sx / s  (若提示找不到命令, 重新登录 shell 即可)"
# SX: 安装完成后自动安装/更新 sing-box 最新稳定版内核 (等同菜单 [15] 选项 1)
echo ""
echo "  ---------- install sing-box core ----------"
if SX_AUTO_INSTALL_CORE=1 bash "$DEST/singbox.sh"; then
    echo "  sing-box core install/update done"
else
    echo "  sing-box core install failed; install later via sx menu [15]"
fi

# SX: 安装完成直接拉起主菜单, 免去再手动敲一遍
if [ -t 0 ]; then
    echo ""
    echo "  ──────────── 进入主菜单 ────────────"
    bash "$DEST/singbox.sh"
    if [ -f "$DEST/singbox.sh" ]; then
        echo ""
        echo "  (已退出主菜单, 下次进入: bash sx)"
    fi
else
    echo "  (非交互环境, 跳过自动启动菜单)"
fi

