#!/bin/bash
# SX v1.0: 身份整合为 v1.0 —— CF-A 不再独立, 本文件只管「CF 云端资源 + state」;
# 节点 inbound 以 cfa- 前缀原子并入主 sing-box (经主脚本无头入口 cfa-apply / cfa-remove);
# 服务 = 主 sing-box.service, relay.json 全局规则 (WARP/中转/落地) 对 CF-A 天然生效。
# 错误处理由 die() 主动把关, 不依赖 set -e (set -e 已移除, 防交互向导静默中断)。
# ┌─ 文件说明（配置地基）─────────────────────────────
# │ cf_lite.sh = CF-A 子脚本：CF 云端资源 (DNS / Origin Rules / Origin 证书 / 凭据) + state + 链接快照
# │ 地基：/etc/sing-box-cf-lite/{state.json, cf_account.json, origin.pem, origin.key, origin.csr}
# │       cf_account.json 同时是 CF-A/CF-B 凭据互通的互读中枢
# │ 节点本地落位 = gen_cfa_inbounds 产出 cfa-* 入站 → 主脚本 cfa-apply 并入主 config.json
# │ （服务不再是独立 sing-box-cf；重启/状态 = 主 sing-box）
# └───────────────────────────────────────────────
STATE_DIR="/etc/sing-box-cf-lite"
STATE_PATH="$STATE_DIR/state.json"
CF_ACCOUNT_PATH="$STATE_DIR/cf_account.json"
ORIGIN_CERT_PATH="$STATE_DIR/origin.pem"
ORIGIN_KEY_PATH="$STATE_DIR/origin.key"
ORIGIN_CSR_PATH="$STATE_DIR/origin.csr"
LAST_LINKS_PATH="$(pwd)/cf_lite_last_links.txt"
export CF_LITE_VERSION="1.0"

CF_API="https://api.cloudflare.com/client/v4"
MANAGED_PREFIX="sing-box-cf-lite "
PREFERRED_SUB_BASE="https://sub.eooce.xx.kg"

# 主脚本 (cfa-apply / cfa-remove 无头入口在这里)
SINGBOX_MAIN_SCRIPT="/usr/local/etc/sx-cf-lite/singbox.sh"

# 主脚本是否存在且具备 cfa-apply / cfa-remove 无头接口 (低于该版本的 singbox.sh 直接拒绝)
main_cfa_ready() {
    local main_sh; main_sh=$(find_main_script) || return 1
    grep -q "cfa-apply" "$main_sh" 2>/dev/null || return 1
    grep -q "cfa-remove" "$main_sh" 2>/dev/null || return 1
    printf '%s' "$main_sh"
}

declare -A PROTO_SUFFIX=([vless]="vl")
declare -A PROTO_LABEL=([vless]="VLESS")

# ── 工具 ──────────────────────────────────────────────
die()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
# 状态提示一律走 stderr：有些函数用 stdout 返回 JSON（如 cf_relax_security），
# 提示混进去会让调用方的 $(...) 拿到「提示+JSON」，jq --argjson 直接解析失败。
ok()      { printf '\033[32m✓\033[0m %s\n' "$*" >&2; }
info()    { printf '\033[36m·\033[0m %s\n' "$*" >&2; }
warn()    { printf '\033[33m⚠ %s\033[0m\n' "$*" >&2; }
need_cmd(){ command -v "$1" &>/dev/null || die "缺少依赖: $1"; }


urlencode() {
    local s="$1" c
    local -i i
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}

gen_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]'; }

# ── init 系统检测 ─────────────────────────────────────
INIT_SYSTEM=""
detect_init() {
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        die "不支持的 init 系统（需要 systemd 或 OpenRC）"
    fi
}

# ── 包管理器 ──────────────────────────────────────────
install_deps() {
    local missing=()
    command -v curl    &>/dev/null || missing+=(curl)
    command -v jq      &>/dev/null || missing+=(jq)
    command -v unzip   &>/dev/null || missing+=(unzip)
    command -v openssl &>/dev/null || missing+=(openssl)
    [[ ${#missing[@]} -eq 0 ]] && return

    echo "安装依赖: ${missing[*]}"
    if command -v apk &>/dev/null; then
        apk add --no-cache "${missing[@]}"
    elif command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq "${missing[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y "${missing[@]}"
    else
        die "无法安装依赖 ${missing[*]}，请手动安装"
    fi
}

# ── 源站接入管理 (经主脚本无头管线, 原子并入主 sing-box) ──
find_main_script() {
    local p
    for p in "$(dirname "$(readlink -f "$0")")/singbox.sh" "$SINGBOX_MAIN_SCRIPT"; do
        [ -f "$p" ] && { printf '%s' "$p"; return 0; }
    done
    return 1
}

# apply_cfa_inbounds <inbounds_json_array>
# 经主脚本 cfa-apply: 端口冲突检查 → 原子替换主配置中全部 cfa-* 入站 →
# config+relay 组合校验 → 重启主服务 (失败自动回滚, 原配置不动)
apply_cfa_inbounds() {
    local main_sh; main_sh=$(main_cfa_ready) \
        || die "主脚本缺少 cfa-apply 接口或不存在, 请先在主菜单 [13] 更新脚本后重试"
    local payload; payload=$(mktemp /tmp/cfa-payload.XXXXXX) || die "创建临时文件失败"
    if ! jq -n --argjson inb "$1" '{inbounds:$inb}' > "$payload" 2>/dev/null; then
        rm -f "$payload"; die "CF-A inbound payload 构造失败"
    fi
    if ! bash "$main_sh" cfa-apply "$payload"; then
        rm -f "$payload"; die "并入主 sing-box 失败 (原配置未动)"
    fi
    rm -f "$payload"
}

# remove_cfa_inbounds: 从主配置移除全部 cfa-* 入站 (删除节点/卸载本地侧)
remove_cfa_inbounds() {
    local main_sh; main_sh=$(main_cfa_ready) \
        || die "主脚本缺少 cfa-remove 接口或不存在, 请先在主菜单 [13] 更新脚本后重试"
    bash "$main_sh" cfa-remove || warn "主配置 CF-A 入站清理未完成"
}

# CF-A 并入主服务 —— 重启/状态一律指主 sing-box
restart_singbox() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl restart sing-box || die "sing-box 重启失败"
        sleep 1
        systemctl is-active sing-box &>/dev/null || die "sing-box 未正常启动，请查看日志"
    else
        rc-service sing-box restart || die "sing-box 重启失败"
        sleep 1
        rc-service sing-box status &>/dev/null 2>&1 || die "sing-box 未正常启动，请查看日志"
    fi
    ok "主 sing-box 服务已重启 (CF-A 节点随服务生效)"
}

svc_is_active() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active sing-box &>/dev/null
    else
        rc-service sing-box status &>/dev/null 2>&1
    fi
}

# ── 网络检测 ─────────────────────────────────────────
get_public_ip() {
    local ip
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        ip=$(curl -sf --max-time 8 "$url" 2>/dev/null) && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return
    done
    die "获取公网 IPv4 失败"
}

# detect_nat 猜测本机是直连公网还是在 NAT 后面。
#
# 只看「公网 IP 有没有绑在网卡上」会误判：云厂商（AWS/GCP/阿里云等）常用一对一 NAT，
# 网卡上是内网地址，但公网端口其实直达。这类机器判成 NAT 会逼用户去填并不存在的端口映射。
# 所以这里只作为默认建议，最终由用户确认（见 prompt_net_mode）。
detect_nat() {
    local public_ip
    public_ip=$(get_public_ip)
    if ip addr show 2>/dev/null | grep -qE "inet ${public_ip}/"; then
        echo "direct"
        return
    fi
    echo "nat"
}

# prompt_net_mode 拿探测结果当默认值，让用户可以改。
#
# 探测不可能百分百准，判错了又没法改的话，装出来的配置就是错的（issue #1）。
net_mode_label() {
    [[ "$1" == "direct" ]] && echo "直连（公网端口直达本机）" || echo "NAT（需要端口映射）"
}

prompt_net_mode() {
    local ans
    echo >&2
    echo "  提示: 有独立公网 IP(含云厂商一对一 NAT)外网可直达端口的选 1; 端口需映射的选 2。" >&2
    read -rp "使用哪种模式? (1=直连, 2=NAT, 回车=默认NAT): " ans
    case "$ans" in
        1) echo "direct" ;;
        2) echo "nat" ;;
        "") echo "nat" ;;
        *) die "无效选择: $ans" ;;
    esac
}

get_listening_ports() {
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | tr '\n' ' '
}

rand_port() {
    local existing="$1" p
    while true; do
        p=$(( RANDOM % 50000 + 10000 ))
        echo "$existing" | grep -qw "$p" || { echo "$p"; return; }
    done
}

# SX: CF 可代理端口矩阵 (HTTPS 侧, 分享链接固定 TLS) —— 客户端 TLS 只能从这些端口过 CF 边缘
CF_HTTPS_PORTS=(443 2053 2083 2087 2096 8443)
cf_matrix_port() {
    local existing="$1" p
    for p in "${CF_HTTPS_PORTS[@]}"; do
        echo "$existing" | grep -qw "$p" || { echo "$p"; return; }
    done
    die "CF 可代理端口 443/2053/2083/2087/2096/8443 均被本机占用, 请释放其一后重试"
}

# ── CF API ────────────────────────────────────────────
cf_call() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -f -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${CF_API}${endpoint}"
}

cf_call_raw() {
    local method="$1" endpoint="$2" data="${3:-}"
    local args=(-s -X "$method" -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(-d "$data")
    curl "${args[@]}" "${CF_API}${endpoint}"
}

# ── CF 凭据 ───────────────────────────────────────────
CF_EMAIL="" CF_KEY=""

# SX: 跨脚本复用 —— CF-B (singbox-lite_tunnel) 在 /usr/local/etc/sing-box/cf_account.json 的已存凭据
load_cf_account_cross() {
    local f="/usr/local/etc/sing-box/cf_account.json"
    [[ -s "$f" ]] || return 1
    CF_EMAIL=$(jq -r '.email // ""' "$f" 2>/dev/null)
    CF_KEY=$(jq -r '.api_key // ""' "$f" 2>/dev/null)
    [[ -n "$CF_EMAIL" && -n "$CF_KEY" ]]
}

load_cf_account() {
    if [[ -f "$CF_ACCOUNT_PATH" ]]; then
        CF_EMAIL=$(jq -r '.email // ""' "$CF_ACCOUNT_PATH")
        CF_KEY=$(jq -r '.api_key // ""' "$CF_ACCOUNT_PATH")
        [[ -n "$CF_EMAIL" && -n "$CF_KEY" ]] && return 0
    fi
    # SX: 回退 CF-B (singbox-lite_tunnel) 的已存凭据
    load_cf_account_cross
}

save_cf_account() {
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    jq -n --arg e "$CF_EMAIL" --arg k "$CF_KEY" '{email:$e,api_key:$k}' > "$CF_ACCOUNT_PATH"
    chmod 600 "$CF_ACCOUNT_PATH"
}

# 验证 CF 凭据是否有效（用 verify 接口，避免拿到无效 key 继续跑）
cf_verify_credentials() {
    local r
    r=$(curl -s -X GET "${CF_API}/user/tokens/verify" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    # Global API Key 在 tokens/verify 上可能不适用，回退到列 zones 验证
    if echo "$r" | jq -e '.success == true' &>/dev/null; then
        return 0
    fi
    r=$(curl -s -X GET "${CF_API}/zones?per_page=1" \
        -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" -H "Content-Type: application/json")
    echo "$r" | jq -e '.success == true' &>/dev/null
}

prompt_cf() {
    # SX: 已保存凭据 (本目录 或 CF-B tunnel 版的) 有效 → 直接复用，不再重复询问
    if load_cf_account && cf_verify_credentials; then
        if [[ -f "$CF_ACCOUNT_PATH" ]]; then
            echo "复用已保存 CF 凭据 ($CF_EMAIL, Key=${CF_KEY:0:6}...)"
        else
            # 来自 CF-B 的跨脚本凭据: 校验通过后落到自己的凭据文件, 后续不再依赖 sing-box 目录
            echo "复用 CF-B (Argo) 已保存 CF 凭据 ($CF_EMAIL)"
            save_cf_account
        fi
        return 0
    fi
    # 本目录凭据失效时, 再试 CF-B 的
    if load_cf_account_cross && cf_verify_credentials; then
        echo "复用 CF-B (Argo) 已保存 CF 凭据 ($CF_EMAIL)"
        save_cf_account
        return 0
    fi
    # 循环让用户输入直到校验通过
    while true; do
        read -rp "Cloudflare 邮箱: " CF_EMAIL || die "输入已中断"
        read -rsp "Cloudflare Global API Key: " CF_KEY || die "输入已中断"; echo
        if [[ -z "$CF_EMAIL" || -z "$CF_KEY" ]]; then
            echo "邮箱和 API Key 不能为空，请重试"
            continue
        fi
        echo -n "校验凭据... "
        if cf_verify_credentials; then
            echo "通过"
            save_cf_account
            return 0
        fi
        echo "失败：邮箱或 API Key 错误，请重新输入（Ctrl+C 退出）"
    done
}

# ── CF DNS / SSL / Origin Rules ───────────────────────
cf_find_zone() {
    local domain="$1" zones best_name="" best_id=""
    zones=$(cf_call GET "/zones?per_page=100" | jq -r '.result[] | "\(.name) \(.id)"')
    while IFS=' ' read -r zone_name zone_id; do
        if [[ "$domain" == "$zone_name" || "$domain" == *".$zone_name" ]]; then
            [[ ${#zone_name} -gt ${#best_name} ]] && best_name="$zone_name" && best_id="$zone_id"
        fi
    done <<< "$zones"
    [[ -n "$best_id" ]] || return 1
    echo "$best_id"
}

cf_get_dns() {
    cf_call GET "/zones/$1/dns_records?type=A&name=$2" | jq '.result[0] // empty'
}

cf_upsert_dns() {
    local zone_id="$1" domain="$2" ip="$3"
    local payload all resp rec rtype rid fcontent
    payload=$(jq -n --arg n "$domain" --arg c "$ip" '{type:"A",name:$n,content:$c,proxied:true,ttl:1}')

    # 同名现有记录（不限类型都要检查）：直接 POST 在有同名 CNAME/AAAA 时会被 CF 静默拒绝
    all=$(cf_call_raw GET "/zones/${zone_id}/dns_records?name=${domain}&per_page=50" 2>/dev/null || true)

    # 1) 已有 A 记录：更新内容即可
    rec=$(echo "$all" | jq -r '.result[]? | select(.type=="A") | .id' 2>/dev/null | head -n1)
    if [[ -n "$rec" ]]; then
        resp=$(cf_call_raw PUT "/zones/${zone_id}/dns_records/${rec}" "$payload")
        if ! echo "$resp" | jq -e '.success' >/dev/null 2>&1; then
            die "更新 DNS A 记录失败: $(echo "$resp" | jq -c '.errors')"
        fi
        echo "$resp" | jq -r '.result.id'
        return 0
    fi

    # 2) 同名非 A 记录：以前 Argo 固定隧道残留的 CNAME (*.cfargotunnel.com) 自动替换；
    #    其他来源的记录绝不擅动，明确报错由用户处理
    while IFS=$'\t' read -r rtype rid fcontent; do
        [[ -n "$rid" ]] || continue
        if [[ "$rtype" == "CNAME" && "$fcontent" == *.cfargotunnel.com ]]; then
            cf_call_raw DELETE "/zones/${zone_id}/dns_records/${rid}" >/dev/null 2>&1 || true
            info "已清理残留隧道 CNAME: ${domain} -> ${fcontent}"
        else
            die "无法创建 DNS 记录: ${domain} 已存在 ${rtype} 记录 (${fcontent})，请先到 CF 后台删除该同名记录后重试"
        fi
    done < <(echo "$all" | jq -r '.result[]? | [.type, .id, .content] | @tsv' 2>/dev/null)

    # 3) 创建 A 记录（必须显式校验 success，失败明确报错退出）
    resp=$(cf_call_raw POST "/zones/${zone_id}/dns_records" "$payload")
    if ! echo "$resp" | jq -e '.success' >/dev/null 2>&1; then
        die "创建 DNS 记录失败: $(echo "$resp" | jq -c '.errors')"
    fi
    echo "$resp" | jq -r '.result.id'
}

cf_get_ssl()  { cf_call GET "/zones/$1/settings/ssl" | jq -r '.result.value'; }
cf_set_ssl()  { cf_call PATCH "/zones/$1/settings/ssl" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }

# ── CF 安全规则 ───────────────────────────────────────
cf_get_security_level() { cf_call GET "/zones/$1/settings/security_level" | jq -r '.result.value'; }
cf_set_security_level() { cf_call PATCH "/zones/$1/settings/security_level" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }

cf_get_browser_check() { cf_call GET "/zones/$1/settings/browser_check" | jq -r '.result.value'; }
cf_set_browser_check() { cf_call PATCH "/zones/$1/settings/browser_check" "$(jq -n --arg v "$2" '{value:$v}')" >/dev/null; }

cf_get_bot_management() { cf_call_raw GET "/zones/$1/bot_management" | jq '.result // {}'; }

cf_set_bot_fight_off() {
    local zone_id="$1"
    cf_call_raw PUT "/zones/${zone_id}/bot_management" "$(jq -n '{
        enable_js: false,
        sbfm_likely_automated: "allow",
        sbfm_definitely_automated: "allow",
        sbfm_verified_bots: "allow",
        sbfm_static_resource_protection: false
    }')" | jq -e '.success' &>/dev/null
}

# 安装时：备份安全设置 -> 关闭拦截
cf_relax_security() {
    local zone_id="$1"
    local sec_level bot_mgmt browser_check

    sec_level=$(cf_get_security_level "$zone_id")
    browser_check=$(cf_get_browser_check "$zone_id")
    bot_mgmt=$(cf_get_bot_management "$zone_id")

    # 降低 security level
    if [[ "$sec_level" != "essentially_off" ]]; then
        cf_set_security_level "$zone_id" "essentially_off"
        ok "Security Level: essentially_off"
    fi

    # 关闭 Browser Integrity Check
    if [[ "$browser_check" != "off" ]]; then
        cf_set_browser_check "$zone_id" "off"
        ok "Browser Check: off"
    fi

    # 关闭 Bot Fight Mode
    local sbfm_likely
    sbfm_likely=$(echo "$bot_mgmt" | jq -r '.sbfm_likely_automated // ""')
    if [[ "$sbfm_likely" != "allow" ]]; then
        cf_set_bot_fight_off "$zone_id"
        ok "Bot Fight Mode: 已关闭"
    fi

    # 返回备份 JSON
    jq -n --arg sl "$sec_level" --arg bc "$browser_check" --argjson bm "$bot_mgmt"         '{security_level:$sl, browser_check:$bc, bot_management:$bm}'
}

cf_get_origin_rules() {
    local r; r=$(cf_call_raw GET "/zones/$1/rulesets/phases/http_request_origin/entrypoint" 2>/dev/null)
    r=$(echo "$r" | jq -r 'if .success then .result.rules // [] else [] end' 2>/dev/null || true)
    # jq 对空输入 exit 0 + 空输出, || 兜底不触发 —— 显式校验
    if [ -z "$r" ] || ! printf '%s' "$r" | jq -e . >/dev/null 2>&1; then r='[]'; fi
    printf '%s\n' "$r"
}

cf_put_origin_rules() {
    # payload 先构造并校验 —— 空/坏规则数据时 curl 会无 body 发送,
    # CF 必然回 invalid JSON (之前正是这条链让创建流程死在这里)
    local payload
    payload=$(jq -n --argjson r "$2" '{rules:$r}' 2>/dev/null) || true
    if [ -z "$payload" ] || ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
        die "Origin Rules payload 构造失败 (规则数据为空或非 JSON)"
    fi
    local r; r=$(cf_call_raw PUT "/zones/$1/rulesets/phases/http_request_origin/entrypoint" "$payload")
    echo "$r" | jq -e '.success' &>/dev/null || die "Origin Rules 写入失败: $(echo "$r" | jq -c '.errors')"
}

# cf_port = 外部端口（CF Origin Rules 转发的目标端口）
build_new_origin_rules() {
    local domain="$1" routes_json="$2"
    local r
    r=$(echo "$routes_json" | jq --arg d "$domain" --arg pfx "$MANAGED_PREFIX" '[
        .[] | {
            description: ($pfx + .protocol + " " + .path),
            enabled: true,
            expression: ("(http.host eq \"" + $d + "\" and http.request.uri.path eq \"" + .path + "\")"),
            action: "route",
            action_parameters: { origin: { port: .cf_port } }
        }
    ]' 2>/dev/null)
    if [ -z "$r" ] || ! printf '%s' "$r" | jq -e . >/dev/null 2>&1; then r='[]'; fi
    printf '%s\n' "$r"
}

apply_origin_rules() {
    local zone_id="$1" domain="$2" routes_json="$3"
    local existing kept new_managed merged
    existing=$(cf_get_origin_rules "$zone_id")
    # 与删除侧同一套语义匹配：expression 里带引号引用本节点域名的规则先全部移除，
    # 再写入最新规则（避免旧版本脚本写入的残留规则与本条并存）
    kept=$(echo "$existing" | jq --arg d "$domain" '[
        .[] | select(
            (((.expression // "") | ascii_downcase | contains("\"" + ($d|ascii_downcase) + "\""))) | not
        )
    ]' 2>/dev/null)
    # jq 链任何一环空输出都显式兜底 (空串流入 --argjson 会让 merged 为空,
    # 最终 PUT 无 body → CF invalid JSON)
    if [ -z "$kept" ] || ! printf '%s' "$kept" | jq -e . >/dev/null 2>&1; then kept='[]'; fi
    new_managed=$(build_new_origin_rules "$domain" "$routes_json")
    merged=$(jq -n --argjson a "$kept" --argjson b "$new_managed" '$a + $b' 2>/dev/null) || true
    if [ -z "$merged" ] || ! printf '%s' "$merged" | jq -e . >/dev/null 2>&1; then merged="$new_managed"; fi
    if [ -z "$merged" ] || ! printf '%s' "$merged" | jq -e . >/dev/null 2>&1; then merged='[]'; fi
    cf_put_origin_rules "$zone_id" "$merged"
}

# 删除节点专用：移除「expression 里带引号引用本节点域名」的 Origin Rule
# （语义级匹配，eq/==/列表写法通吃，兼容旧版本脚本写入的规则式样）。
# 基于实时规则表过滤回写（不用旧备份），其他规则不受影响；失败不中断删除流程。
cf_remove_node_rules() {
    local zone_id="$1" domain="$2"
    local rules kept n nk r
    rules=$(cf_get_origin_rules "$zone_id")
    # 语义级匹配：expression 里带引号精确引用本节点域名的规则（eq/==/列表写法通吃，
    # 兼容旧版本脚本写入的规则式样；带引号匹配不会误伤前缀相似的其他子域名）
    kept=$(echo "$rules" | jq --arg d "$domain" '[
        .[] | select(
            (((.expression // "") | ascii_downcase | contains("\"" + ($d|ascii_downcase) + "\""))) | not
        )
    ]' 2>/dev/null)
    # 空输出兜底 —— kept 为空串时 PUT 会无 body, CF 回 invalid JSON, 清理静默失败
    if [ -z "$kept" ] || ! printf '%s' "$kept" | jq -e . >/dev/null 2>&1; then kept='[]'; fi
    n=$(echo "$rules" | jq 'length' 2>/dev/null); n=${n:-0}
    nk=$(echo "$kept" | jq 'length' 2>/dev/null); nk=${nk:-0}
    if [[ "$n" == "$nk" ]]; then
        info "Origin Rules 中未找到引用 ${domain} 的规则"
        return 0
    fi
    r=$(cf_call_raw PUT "/zones/$zone_id/rulesets/phases/http_request_origin/entrypoint" \
        "$(jq -n --argjson r "$kept" '{rules:$r}')")
    if echo "$r" | jq -e '.success' &>/dev/null; then
        ok "Origin Rules 已移除本节点规则 ($((n - nk)) 条)"
    else
        info "Origin Rules 清理失败，该节点规则可稍后在 CF 后台手动删除"
    fi
    return 0
}

# ── 无 state 云端残留清理 ────────────────────
# 背景: v34 时代创建失败 —— CF 资源 (DNS/Origin Rules/证书) 已写入但 state.json
# 未落盘, delete / uninstall 在 state 缺失时直接跳过云端清理 → CF 端残留。
# 这里从本地痕迹 (订阅快照链接 / origin 证书 CN) 推断域名, 双保险清理:
#   Origin Rules = 「sing-box-cf-lite 前缀」或「引用推断域名」的规则全删 (跨全部 zone)
#   Origin 证书  = 优先用残留 origin_cert_id 精准吊销 (列表接口对 Global Key 不返数据)
#   DNS          = 推断域名的同名记录全删 (域名未知时跳过)
# 实测坑 (HK): Origin 证书 CN 固定为 "CloudFlare Origin Certificate" 不是域名,
#              只能按"形如域名 (带点)"过滤后采纳; 订阅快照里的 vless 链接最可靠。
_discover_orphan_domain() {
    local d="" lf
    # ① 订阅快照链接 (vless://…@域名) —— 最可靠; 路径随 cwd, 运行目录与安装目录都找
    for lf in "$LAST_LINKS_PATH" "${STATE_DIR}/cf_lite_last_links.txt"; do
        [ -f "$lf" ] || continue
        d=$(grep -aoE 'vless://[^@]+@[a-zA-Z0-9.-]+' "$lf" 2>/dev/null \
            | head -n 1 | sed 's/.*@//')
        [ -n "$d" ] && break
    done
    # ② origin 证书 CN —— 仅当形如域名 (带点、无空格) 时才采纳
    if [ -z "$d" ] && [ -f "$ORIGIN_CERT_PATH" ]; then
        local cn
        cn=$(openssl x509 -in "$ORIGIN_CERT_PATH" -noout -subject 2>/dev/null \
            | sed -n 's/.*CN *= *\([^ ,]\+\).*/\1/p' | head -n 1 | sed 's/^\*\.//')
        if [[ "$cn" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
            d="$cn"
        fi
    fi
    printf '%s' "$d"
}

cleanup_orphan_residue() {
    load_cf_account 2>/dev/null || true
    if [ -z "$CF_EMAIL" ] || [ -z "$CF_KEY" ]; then
        info "无 CF 凭据, 跳过云端残留清理 (如需要请到 CF 后台手动核对)。"
        return 0
    fi
    local dom
    dom=$(_discover_orphan_domain)
    info "无 state 云端残留清理${dom:+ (推断域名: ${dom})}"

    # Origin Rules: 扫全部 zone, 删「本脚本前缀」或「引用推断域名」的规则
    local zones zid
    zones=$(cf_call_raw GET "/zones?per_page=50" 2>/dev/null || true)
    if [ -z "$zones" ] || ! printf '%s' "$zones" | jq -e '.success == true' >/dev/null 2>&1; then
        info "无法列出 zones, 跳过 Origin Rules 残留清理。"
    else
        while IFS= read -r zid; do
            [ -n "$zid" ] || continue
            local rules kept n nk payload r
            rules=$(cf_get_origin_rules "$zid")
            n=$(printf '%s' "$rules" | jq 'length' 2>/dev/null); n=${n:-0}
            kept=$(printf '%s' "$rules" | jq --arg d "$dom" --arg pfx "$MANAGED_PREFIX" '
                [ .[] | select(
                    (((.description // "") | startswith($pfx)) | not)
                    and (( $d == "" )
                         or ((((.expression // "") | ascii_downcase)
                              | contains("\"" + ($d|ascii_downcase) + "\"")) | not))
                ) ]' 2>/dev/null)
            if [ -z "$kept" ] || ! printf '%s' "$kept" | jq -e . >/dev/null 2>&1; then
                continue
            fi
            nk=$(printf '%s' "$kept" | jq 'length' 2>/dev/null); nk=${nk:-0}
            [ "$n" -gt "$nk" ] || continue
            payload=$(jq -nc --argjson r "$kept" '{rules:$r}' 2>/dev/null) || payload=""
            [ -n "$payload" ] || continue
            r=$(cf_call_raw PUT "/zones/$zid/rulesets/phases/http_request_origin/entrypoint" "$payload" 2>/dev/null)
            if printf '%s' "$r" | jq -e '.success' >/dev/null 2>&1; then
                ok "Origin Rules 已清理 $((n - nk)) 条 (zone ${zid:0:8}...)"
            else
                info "Origin Rules 清理失败 (zone ${zid:0:8}...)"
            fi
        done < <(printf '%s' "$zones" | jq -r '.result[]?.id // empty' 2>/dev/null)
    fi

    # Origin 证书: 优先用残留 origin_cert_id 精准吊销 (HK 实测: 列表接口对 Global Key 返回空);
    # 无 id 文件但已知域名时按 hostnames 兜底 (权限不足/找不到则明确提示人工处理)
    local cert_file="${STATE_DIR}/origin_cert_id" cert_done=0
    if [ -s "$cert_file" ]; then
        local cid0
        cid0=$(head -n 1 "$cert_file" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$cid0" ]; then
            if cf_call_raw DELETE "/certificates/${cid0}" 2>/dev/null | jq -e '.success' >/dev/null 2>&1; then
                ok "已吊销残留 Origin 证书 (id: ${cid0:0:8}...)"
                rm -f "$cert_file"
                cert_done=1
            else
                info "残留证书吊销失败 (id: ${cid0:0:8}...), 保留 origin_cert_id 供重试。"
            fi
        fi
    fi
    if [ "$cert_done" -eq 0 ] && [ -n "$dom" ]; then
        local clist cid chosts
        clist=$(cf_call_raw GET "/certificates?per_page=100" 2>/dev/null || true)
        if [ -n "$clist" ] && printf '%s' "$clist" | jq -e '(.success == true) and ((.result // []) | length > 0)' >/dev/null 2>&1; then
            while IFS=$'\t' read -r cid chosts; do
                [ -n "$cid" ] || continue
                [ "$chosts" == "$dom" ] || continue
                if cf_call_raw DELETE "/certificates/${cid}" >/dev/null 2>&1; then
                    ok "已吊销残留 Origin 证书: ${chosts}"
                    cert_done=1
                else
                    info "残留证书吊销失败: ${chosts} (可稍后在 CF 后台手动删除)"
                fi
            done < <(printf '%s' "$clist" | jq -r '.result[]? | [.id, (.hostnames | join(","))] | @tsv' 2>/dev/null)
        fi
    fi
    [ "$cert_done" -eq 0 ] && info "残留 Origin 证书未能自动定位${dom:+ (需要检查域名: ${dom})}, 请在 CF 后台 SSL/TLS → Origin Server 手动核对。"

    # DNS: 推断域名的同名记录全删
    if [ -n "$dom" ]; then
        local dzid rids rid
        dzid=$(cf_find_zone "$dom" 2>/dev/null || true)
        if [ -n "$dzid" ]; then
            rids=$(cf_call_raw GET "/zones/${dzid}/dns_records?name=${dom}" 2>/dev/null \
                | jq -r '.result[]?.id // empty' 2>/dev/null || true)
            if [ -n "$rids" ]; then
                while IFS= read -r rid; do
                    [ -n "$rid" ] || continue
                    cf_call_raw DELETE "/zones/${dzid}/dns_records/${rid}" >/dev/null 2>&1 || true
                done <<< "$rids"
                ok "残留 DNS 记录已删除: ${dom}"
            fi
        fi
    fi
}

# ── CF Origin 证书（Full Strict 用）──────────────────
# 生成 key + CSR，调 CF API 签发 Origin 证书并保存到 STATE_DIR。
# 证书由 CF 信任、有效期 15 年，无需续期；CF SSL 设 strict 时启用。
cf_setup_origin_cert() {
    local zone_id="$1" domain="$2"
    info "生成 Origin 证书（Full Strict）..."
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$ORIGIN_KEY_PATH" \
        -out "$ORIGIN_CSR_PATH" \
        -subj "/CN=${domain}" 2>/dev/null \
        || die "生成 CSR 失败"

    local csr_pem payload r cert
    csr_pem=$(cat "$ORIGIN_CSR_PATH")
    payload=$(jq -n --arg csr "$csr_pem" --arg d "$domain" \
        '{csr:$csr, hostnames:[$d], request_type:"origin-rsa", requested_validity:5475}')
    r=$(cf_call_raw POST "/certificates" "$payload")
    cert=$(echo "$r" | jq -r '.result.certificate // empty')
    [[ -n "$cert" ]] || die "创建 Origin 证书失败: $(echo "$r" | jq -c '.errors // empty')"

    echo "$cert" > "$ORIGIN_CERT_PATH"
    chmod 600 "$ORIGIN_CERT_PATH" "$ORIGIN_KEY_PATH"
    rm -f "$ORIGIN_CSR_PATH"
    # 保存证书 ID，删除节点/卸载时用于精确吊销 CF 账号侧证书
    local cert_id
    cert_id=$(echo "$r" | jq -r '.result.id // empty')
    if [[ -n "$cert_id" ]]; then
        [[ -d "$STATE_DIR" ]] || mkdir -p "$STATE_DIR"
        printf '%s' "$cert_id" > "$STATE_DIR/origin_cert_id"
        chmod 600 "$STATE_DIR/origin_cert_id" 2>/dev/null || true
    fi
    ok "Origin 证书已保存: $ORIGIN_CERT_PATH"
}

# grant_cert_access 已移除 —— CF-A 入站引用 STATE_DIR 证书路径,
# 主 sing-box 服务以 root 运行, 不再存在 nobody 读证书的问题。

gen_cfa_inbounds() {
    # 只生成 inbound 数组；整份配置的组装/校验/重启都在主脚本 cfa-apply 完成。
    # tag 统一 cfa- 前缀 —— 这是主配置里识别本组入站、增删改分流的唯一依据。
    local routes_json="$1" uid="$2" ssl_mode="${3:-flexible}"
    local tls_enabled="false"
    [[ "$ssl_mode" == "strict" ]] && tls_enabled="true"
    local inbounds
    inbounds=$(echo "$routes_json" | jq --arg uid "$uid" --argjson tls "$tls_enabled" \
        --arg cert "$ORIGIN_CERT_PATH" --arg key "$ORIGIN_KEY_PATH" '[
        .[] | {
            type: "vless",
            tag: ("cfa-vless-" + (.listen_port|tostring)),
            listen: "0.0.0.0",
            listen_port: .listen_port,
            users: [{uuid: $uid, flow: ""}],
            transport: {type: "ws", path: .path},
            tls: (if $tls then {enabled:true, certificate_path:$cert, key_path:$key, alpn:["http/1.1"]} else {enabled:false} end)
        }
    ]')
    if [ -z "$inbounds" ] || ! printf '%s' "$inbounds" | jq -e 'type == "array"' >/dev/null 2>&1; then
        die "CF-A inbound 生成失败 (输出为空或非数组)"
    fi
    printf '%s\n' "$inbounds"
}

# ── 节点链接 ─────────────────────────────────────────
build_link() {
    # 单个 VLESS 节点：直连域名（走 CF 橙云 + Origin Rules）
    local uid="$1" domain="$2" cf_port="$3" path="$4"
    echo "vless://${uid}@${domain}:${cf_port}?encryption=none&security=tls&sni=${domain}&fp=chrome&type=ws&host=${domain}&path=$(urlencode "$path")#CF-A-${cf_port}"
}

gen_all_links() {
    local uid="$1" domain="$2" routes_json="$3"
    local links_json='{}'
    local proto path link
    while IFS=$'\t' read -r proto cfp path; do
        link=$(build_link "$uid" "$domain" "$cfp" "$path")
        links_json=$(echo "$links_json" | jq --arg p "$proto" --arg l "$link" '. + {($p):$l}')
    done < <(echo "$routes_json" | jq -r '.[] | [.protocol, (.edge_port // .cf_port|tostring), .path] | @tsv')
    echo "$links_json"
}

# ── 状态 ──────────────────────────────────────────────
load_state() { [[ -f "$STATE_PATH" ]] && cat "$STATE_PATH"; }
save_state() { mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"; echo "$1" > "$STATE_PATH"; chmod 600 "$STATE_PATH"; }
remove_state() { rm -f "$STATE_PATH"; }

save_links_snapshot() {
    local domain="$1" uid="$2" links_json="$3"
    { echo "域名: $domain"; echo "UUID: $uid"; echo
      echo "$links_json" | jq -r 'to_entries[] | "\(.key) \(.value)"'
    } > "$LAST_LINKS_PATH"
    chmod 600 "$LAST_LINKS_PATH"
}

print_links() {
    local links_json="$1"
    local proto link
    while IFS=$'\t' read -r proto link; do
        echo "  ${PROTO_LABEL[$proto]:-$proto}节点 $link"
    done < <(echo "$links_json" | jq -r 'to_entries[] | [.key, .value] | @tsv')
}

# ── 交互辅助 ─────────────────────────────────────────
prompt_uuid() {
    local uid
    read -rp "UUID(留空=自动生成): " custom_uuid
    if [[ -n "$custom_uuid" ]]; then
        [[ "$custom_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式不正确"
        uid="${custom_uuid,,}"
    else
        uid=$(gen_uuid)
    fi
    echo "$uid"
}

prompt_path_prefix() {
    local default="$1"
    read -rp "WS 路径前缀(留空=/${default}): " pfx
    [[ -z "$pfx" ]] && pfx="/${default}"
    [[ "$pfx" == /* ]] || pfx="/${pfx}"
    echo "$pfx"
}

prompt_ssl_mode() {
    echo >&2
    info "SSL 模式:" >&2
    echo "  1 = 严格 Full Strict（推荐）：源站启用 HTTPS + Origin 证书，更安全" >&2
    echo "  2 = 灵活 Flexible：源站走 HTTP，配置简单" >&2
    read -rp "选择 SSL 模式 (1=严格, 2=灵活, 回车=严格): " ans
    case "$ans" in
        2) echo "flexible" ;;
        *) echo "strict" ;;
    esac
}

# 生成路由 JSON，NAT 和直连通用
# NAT 时本机监听 listen_port(内部)，CF 转发到 cf_port(外部)
# 直连时 listen_port == cf_port
build_routes() {
    local net_mode="$1" path_prefix="$2" proto_count="$3"
    shift 3
    local protocols=("$@")

    local routes_json='[]'

    if [[ "$net_mode" == "nat" ]]; then
        echo >&2
        info "NAT 模式: 逐个配置每个协议的端口映射" >&2
        echo >&2

        for proto in "${protocols[@]}"; do
            local int_port ext_port
            read -rp "${proto} 内部监听端口(本机监听, 回车=默认443): " int_port
            int_port=${int_port:-443}
            [[ "$int_port" =~ ^[0-9]+$ ]] || die "无效端口: $int_port"
            read -rp "${proto} 外部映射端口(对外暴露): " ext_port
            [[ "$ext_port" =~ ^[0-9]+$ ]] || die "无效端口: $ext_port"
            local path="${path_prefix}-${PROTO_SUFFIX[$proto]}"
            routes_json=$(echo "$routes_json" | jq \
                --arg p "$proto" --argjson lp "$((int_port))" --argjson cp "$((ext_port))" --arg pa "$path" \
                '. + [{protocol:$p, listen_port:$lp, cf_port:$cp, edge_port:443, path:$pa}]')
        done
    else
        read -rp "自定义端口?(逗号分隔, 回车=自动选CF可代理端口): " custom_ports_raw
        local existing_ports
        existing_ports=$(get_listening_ports)
        local custom_ports=()
        if [[ -n "$custom_ports_raw" ]]; then
            IFS=',' read -ra custom_ports <<< "$custom_ports_raw"
            [[ ${#custom_ports[@]} -eq $proto_count ]] || die "端口数量与协议数不一致"
        fi

        local pi=0
        for proto in "${protocols[@]}"; do
            local port
            if [[ ${#custom_ports[@]} -gt 0 ]]; then
                port="${custom_ports[$pi]// /}"
                [[ "$port" =~ ^[0-9]+$ ]] || die "无效端口: $port"
                echo "$existing_ports" | grep -qw "$port" && die "端口本机已被占用: $port (释放重试, 或回车自动选 443 2053 2083 2087 2096 8443)"
                case " ${CF_HTTPS_PORTS[*]} " in *" $port "*) ;; *) die "端口 $port 不在 CF 可代理范围, 客户端连不上 (允许: 443 2053 2083 2087 2096 8443)" ;; esac
            else
                port=$(cf_matrix_port "$existing_ports")
            fi
            existing_ports="$existing_ports $port"
            local path="${path_prefix}-${PROTO_SUFFIX[$proto]}"
            routes_json=$(echo "$routes_json" | jq \
                --arg p "$proto" --argjson lp "$((port))" --arg pa "$path" \
                '. + [{protocol:$p, listen_port:$lp, cf_port:$lp, edge_port:$lp, path:$pa}]')
            pi=$((pi + 1))
        done
    fi

    echo "$routes_json"
}

# ── 1. 安装 ──────────────────────────────────────────
do_install() {
    local state
    state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] && die "检测到上次配置($(echo "$state" | jq -r '.domain // "?"'))，请先卸载"

    _sx_script=""
    for _p in "$(dirname "$(readlink -f "$0")")/singbox.sh" "$SINGBOX_MAIN_SCRIPT"; do
        [ -f "$_p" ] && { _sx_script="$_p"; break; }
    done
    if [ -n "$_sx_script" ]; then
        SX_AUTO_INSTALL_CORE=1 bash "$_sx_script" || die "sing-box 核心安装/更新失败"
        ok "sing-box 核心已就绪"
    else
        die "未找到 singbox.sh 主脚本 (进主菜单跑一次 [15] 或先安装主脚本)"
    fi

    local net_mode
net_mode=$(prompt_net_mode)
    ok "网络模式: $(net_mode_label "$net_mode")"

    prompt_cf

    # 输入域名并校验能匹配到 CF Zone，失败可重输
    local domain zone_id
    while true; do
        read -rp "绑定域名: " domain || die "输入已中断"
        if [[ -z "$domain" ]]; then
            echo "域名不能为空，请重试"
            continue
        fi
        if zone_id=$(cf_find_zone "$domain"); then
            info "匹配到 Zone: $zone_id"
            break
        fi
        echo "无法在该 CF 账号下匹配 Zone: $domain，请确认域名已托管并重输（Ctrl+C 退出）"
    done

    local protocols=(vless)

    uid=$(gen_uuid)
    # SX: 全自动 —— UUID 随机生成, WS 路径 = /<short_id>, 不再提问
    local short_id="${uid:0:8}"
    local path_prefix="/${short_id}"

    local ssl_mode
    local ssl_mode="strict"
    # SX: 全自动 —— SSL 固定严格模式 (Full Strict + Origin 证书), 不再提问

    local routes_json
    routes_json=$(build_routes "$net_mode" "$path_prefix" "${#protocols[@]}" "${protocols[@]}")

    # 预览
    echo
    echo "配置预览:"
    echo "  域名:  $domain"
    echo "  UUID:  $uid"
    echo "  模式:  $net_mode"
    echo "  SSL:   $ssl_mode"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port)  CF端口:\(.cf_port)  路径:\(.path)"'
    echo
    # SX: 全自动 —— 免人工确认, 直接部署
    true

    # 源站: cf_setup_origin_cert 先落证书 (strict 模式 cfa-apply 组合校验需要读到证书文件),
    # 之后 inbound 经主脚本管线并入主 sing-box —— 服务/端口冲突/回滚全由主侧把守
    if [[ "$ssl_mode" == "strict" ]]; then
        cf_setup_origin_cert "$zone_id" "$domain"
    fi
    local inbounds_json
    inbounds_json=$(gen_cfa_inbounds "$routes_json" "$uid" "$ssl_mode")
    apply_cfa_inbounds "$inbounds_json"

    # CF
    local public_ip dns_before ssl_before origin_rules_before dns_record_id
    public_ip=$(get_public_ip)
    dns_before=$(cf_get_dns "$zone_id" "$domain" || echo "null")
    [[ "$dns_before" == "" ]] && dns_before="null"
    ssl_before=$(cf_get_ssl "$zone_id")
    origin_rules_before=$(cf_get_origin_rules "$zone_id")

    dns_record_id=$(cf_upsert_dns "$zone_id" "$domain" "$public_ip")
    ok "DNS A 记录: $domain -> $public_ip (已代理)"
    cf_set_ssl "$zone_id" "$ssl_mode"
    ok "SSL 模式: $ssl_mode"
    apply_origin_rules "$zone_id" "$domain" "$routes_json"
    ok "Origin Rules: ${#protocols[@]} 条"
    # SX: 部署后自检 v3 —— 先等 DNS 生效再测; CF 边缘实测回源;
    # 000 = 本机->边缘探测链路故障(DNS/TLS/CA/劫持), 与端口无关不轮换; 5xx = 源站端口可达性, 轮换矩阵端口重试
    local _used _try _code _np _cerr _loc _c80 _pass=0
    local _dns=""
    _used=$(echo "$routes_json" | jq -r '.[0].listen_port|tostring')
    for _try in 1 2 3 4 5 6 7; do
        nslookup "${domain}" >/dev/null 2>&1 && { _dns=1; break; }
        sleep 3
    done
    [[ -n "$_dns" ]] || info "提示: 域名 ${domain} 尚未解析生效, 自检结论可能不准" >&2
    for _try in 1 2 3; do
        _code=$(curl -s -o /dev/null -m 20 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -w "%{http_code}" "https://${domain}${path_prefix}-vl") || _code=000
        case "$_code" in 400|404|426) _pass=1; break ;; esac
        if [[ "$_code" == "000" ]]; then
            sleep 6
            _code=$(curl -s -o /dev/null -m 20 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -w "%{http_code}" "https://${domain}${path_prefix}-vl") || _code=000
            case "$_code" in 400|404|426) _pass=1 ;; esac
            [[ "$_pass" == "1" || "$_code" == "000" ]] && break
        fi
        [[ "$_try" == "3" ]] && break
        if [[ "$net_mode" == "nat" ]]; then
            # SX: NAT 模式下外部可达端口由服务商映射面板决定, 本地换端口救不了;
            #     旧逻辑曾把 listen_port/cf_port 一并改写, 把映射端口规则污染成矩阵端口 (NAT 下必死)
            [[ "$_try" == "1" ]] && info "NAT 模式: 跳过端口自动切换 (外部映射以面板为准, 规则保持外部端口)" >&2
            sleep 6
            continue
        fi
        _np=$(for _p in "${CF_HTTPS_PORTS[@]}"; do case " ${_used} " in *" ${_p} "*) ;; *) echo "$_p"; break ;; esac; done)
        [[ -n "$_np" ]] && {
            _used="$_used $_np"
            info "自检失败 (HTTP ${_code}), 自动切换端口为 ${_np} 重试..." >&2
            routes_json=$(echo "$routes_json" | jq --argjson lp "${_np}" '.[0].listen_port=$lp|.[0].cf_port=$lp')
            apply_cfa_inbounds "$(gen_cfa_inbounds "$routes_json" "$uid" "$ssl_mode")"
            apply_origin_rules "$zone_id" "$domain" "$routes_json"
        }
    done

    if [[ "$_pass" == "0" ]]; then
        # 自检失败不再 die —— 节点其实已完整部署 (DNS/SSL/OriginRules/源站全部就位),
        # 只是 CF 边缘回源被云防火墙挡住。die 会导致 state.json 永不写入、查看节点永远空白、
        # 用户反复重建反复失败。改为警告 + 照常保存状态和链接, 端口放行后节点即刻可用。
        warn "部署自检未通过 (HTTP ${_code}) —— 节点已部署, 但以下排查建议供参考:"
        if [[ "$_code" == "000" ]]; then
            _cerr=$(curl -sS -o /dev/null -m 20 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" "https://${domain}${path_prefix}-vl" 2>&1 >/dev/null | head -1)
            _c80=$(curl -s -o /dev/null -m 15 -w "%{http_code}" "http://${domain}${path_prefix}-vl") || _c80=000
            _code=$(curl -sk -o /dev/null -m 20 -w "%{http_code}" "https://${domain}${path_prefix}-vl") || _code=000
            case "$_code" in
                400|404|426)
                    ok "部署自检通过 (HTTP ${_code}, 免证书校验) —— 本机缺 CA 证书, 建议: apk add ca-certificates"
                    ;;
                *)
                    _loc=$(curl -sk -o /dev/null -m 8 -w "%{http_code}" --resolve "${domain}:443:127.0.0.1" "https://${domain}${path_prefix}-vl") || _loc=000
                    case "$_loc" in
                        400|404|426)
                            case "$_c80" in
                                400|404|426|301|308)
                                    warn "自检: HTTP(80口)可达(${_c80}) 但 HTTPS(443)为000 —— 本机 TLS/CA/出站443问题; 建议装 ca-certificates 或换 DNS 1.1.1.1 (curl: ${_cerr:-network})"
                                    ;;
                                *)
                                    warn "自检: 80/443 均 000 (curl: ${_cerr:-network}) 且源站本地正常 —— DNS 刚生效为大概率原因, 等 2 分钟后再装; 或本机出站被拦/劫持"
                                    ;;
                            esac
                            ;;
                        *)
                            warn "自检失败 (HTTP ${_code}) 且源站本地也不通(HTTP ${_loc}) —— 检查: 服务状态与日志"
                            ;;
                    esac
                    ;;
            esac
        else
            if [[ "$net_mode" == "nat" ]]; then
                local _cfp
                _cfp=$(echo "$routes_json" | jq -r '.[0].cf_port // empty')
                warn "自检失败 (HTTP ${_code}): CF 边缘回源 外部端口:${_cfp:-?} 不可达 —— NAT 排查三步: ① 服务商控制台确认端口映射 (外部 ${_cfp:-36000} -> 内部 443) ② 云防火墙/安全组放行该外部端口入站 ③ 映射面板外部端口改为其他端口后需跑 [5] 同步"
            else
                warn "自检失败 (HTTP ${_code}): 该端口向 CF 回源不可达 —— 云防火墙放行 443/2053/2083/2087/2096/8443 后节点即刻可用"
            fi
        fi
    fi

    # 安全规则：关闭可能拦截 WS 的设置
    local security_backup
    security_backup=$(cf_relax_security "$zone_id")

    # 节点链接
    local links_json
    links_json=$(gen_all_links "$uid" "$domain" "$routes_json")
    save_links_snapshot "$domain" "$uid" "$links_json"

    # 状态
    local dns_existed="false"
    [[ "$dns_before" != "null" ]] && dns_existed="true"
    # jq --argjson 遇到空串会整体失败，导致 state.json 存不下来（存不下就没法改配置/卸载）。
    # CF 接口任何一个返回空都不该拖垮状态保存，这里统一兜底成合法 JSON。
    [[ -n "$dns_before" ]]          || dns_before="null"
    [[ -n "$origin_rules_before" ]] || origin_rules_before="[]"
    [[ -n "$security_backup" ]]     || security_backup="null"
    [[ -n "$links_json" ]]          || links_json="{}"
    [[ -n "$routes_json" ]]         || routes_json="[]"
    save_state "$(jq -n \
        --arg d "$domain" --arg z "$zone_id" --arg u "$uid" --arg s "$short_id" --arg mode "$net_mode" \
        --arg sslmode "$ssl_mode" \
        --argjson routes "$routes_json" \
        --arg drid "$dns_record_id" --argjson dex "$dns_existed" --argjson drec "$dns_before" \
        --arg ssl "$ssl_before" --argjson orbk "$origin_rules_before" --argjson links "$links_json" \
        --argjson secbk "$security_backup" \
        '{domain:$d,zone_id:$z,uuid:$u,short_id:$s,net_mode:$mode,ssl_mode:$sslmode,routes:$routes,
          managed_dns_record_id:$drid,dns_backup:{existed:$dex,record:$drec},
          ssl_backup:$ssl,origin_rules_backup:$orbk,security_backup:$secbk,links:$links}')"

    echo
    ok "部署完成"
    print_links "$links_json"
    echo
    echo "节点链接已保存到 $LAST_LINKS_PATH"
}

# ── 删除节点核心清理（删除节点 / 卸载脚本 共用）──────
# 原则：只清理本节点自身（主配置中的 cfa-* 入站、本节点域名的 DNS 解析、
#       本节点域名的 Origin CA 证书吊销、Origin Rules 中本节点自己的规则、本地证书文件）
# 不碰任何 zone 级全局配置：SSL 模式 / 安全规则(Bot Fight 等)都不动，
# Origin Rules 也只按「sing-box-cf-lite 前缀 + host eq 本节点域名」精准剔除，
# 避免影响部署在同一域名下的其他节点。
_delete_node_core() {
    local state="$1"
    local domain zone_id rids rid

    domain=$(echo "$state" | jq -r '.domain // ""')

    remove_cfa_inbounds

    if ! load_cf_account; then
        info "无 CF 凭据，跳过 DNS 清理"
    else
        zone_id=$(echo "$state" | jq -r '.zone_id // ""')
        if [[ -z "$zone_id" ]]; then
            info "state 中无 zone_id，跳过 DNS 清理"
        else
            # DNS：精确匹配本节点域名（二级域名），同名记录（CNAME/A 等）全部删除
            # 注意：不恢复备份、不动 zone 其他配置，确保不影响其他节点
            rids=$(cf_call_raw GET "/zones/${zone_id}/dns_records?name=${domain}" 2>/dev/null | jq -r '.result[]?.id // empty' || true)
            if [[ -n "$rids" ]]; then
                while IFS= read -r rid; do
                    [[ -n "$rid" ]] || continue
                    cf_call_raw DELETE "/zones/${zone_id}/dns_records/${rid}" >/dev/null 2>&1 || true
                done <<< "$rids"
                ok "DNS 解析已删除: $domain"
            else
                info "未找到 $domain 的 DNS 记录"
            fi

            # Origin Rules：只移除本脚本创建、且 host 为本节点域名的规则
            # （实时拉取规则表→精准过滤→回写，不碰全局配置与其他节点的规则）
            cf_remove_node_rules "$zone_id" "$domain" || true
        fi
    fi

    # 证书：吊销 CF 账号侧本节点的 Origin CA 证书（只碰 hostnames 恰好=本节点域名的证书）
    # 新装节点：优先用安装时保存的证书 ID 精确吊销
    # 旧节点：无 ID 时列出账号证书，按 hostnames 精确匹配兜底（多域名的证书绝不吊销）
    local cert_id_path="$STATE_DIR/origin_cert_id"
    local cert_id=""
    [[ -f "$cert_id_path" ]] && cert_id=$(tr -d '[:space:]' < "$cert_id_path" 2>/dev/null)
    if [[ -n "$cert_id" ]]; then
        if cf_call_raw DELETE "/certificates/${cert_id}" >/dev/null 2>&1; then
            ok "已吊销 Origin 证书 (id: ${cert_id})"
        else
            info "Origin 证书吊销失败或已吊销 (id: ${cert_id})，如需要可稍后在 CF 后台手动删除"
        fi
    else
        local clist cid chosts
        clist=$(cf_call_raw GET "/certificates?per_page=100" 2>/dev/null || true)
        if [[ -n "$clist" ]] && echo "$clist" | jq -e '.result != null' >/dev/null 2>&1; then
            while IFS=$'\t' read -r cid chosts; do
                [[ -n "$cid" ]] || continue
                [[ "$chosts" == "$domain" ]] || continue
                if cf_call_raw DELETE "/certificates/${cid}" >/dev/null 2>&1; then
                    ok "已吊销 Origin 证书: ${chosts}"
                else
                    info "Origin 证书吊销失败: ${chosts} (可稍后在 CF 后台手动删除)"
                fi
            done < <(echo "$clist" | jq -r '.result[]? | [.id, (.hostnames | join(","))] | @tsv' 2>/dev/null)
        else
            info "无法列出 CF 账号证书 (凭据权限不足)，该节点旧证书如需清理请到 CF 后台 SSL→源服务器 手动删除"
        fi
    fi
    rm -f "$cert_id_path"

    # 本地证书文件（Origin 证书/私钥/CSR）随节点一起清理
    rm -f "$ORIGIN_CERT_PATH" "$ORIGIN_KEY_PATH" "$ORIGIN_CSR_PATH"
}

# SX: 删除节点不还原 zone 级全局安全项 (SSL/Bot 等), 故配套的 cf_restore_security/
#     cf_restore_bot_management 恢复链一并移除——避免无效代码误导维护者。

# ── 2. 删除节点 ──────────────────────────────────────
do_delete_node() {
    local state
    state=$(load_state 2>/dev/null || true)
    if [[ -z "$state" ]]; then
        # state 丢失 (v34 创建失败的半死状态) —— CF 资源已在云端但本地无账,
        # 按本地痕迹 (origin 证书 CN / 订阅快照) 推断域名做残留清理, 不再直接放弃
        cleanup_orphan_residue
        remove_cfa_inbounds || true
        rm -f "$ORIGIN_CERT_PATH" "$ORIGIN_KEY_PATH" "$ORIGIN_CSR_PATH" "$LAST_LINKS_PATH"
        ok "无已部署节点, 残留清理完成。"
        return 0
    fi

    local domain; domain=$(echo "$state" | jq -r '.domain')
    echo "正在删除节点: $domain"

    _delete_node_core "$state"

    remove_state
    rm -f "$LAST_LINKS_PATH" "$CF_ACCOUNT_PATH" "$ORIGIN_CERT_PATH" "$ORIGIN_KEY_PATH" "$ORIGIN_CSR_PATH"
    ok "已清理节点快照与 CF 凭据"
    ok "节点已删除 (SSL 模式未改动)"
}

# ── 0. 卸载脚本 ──────────────────────────────────────
# 自动读取节点 -> 删除节点 -> 停止服务 -> 删除本地脚本文件
do_uninstall_script() {
    local state
    state=$(load_state 2>/dev/null || true)

    echo
    read -rp "$(printf '\033[31m确定卸载脚本? 将自动删除已部署节点并自删脚本文件 (y/N): \033[0m')" confirm
    [[ "${confirm,,}" =~ ^y(es)?$ ]] || { info "已取消"; return 0; }

    if [[ -n "$state" ]]; then
        info "检测到已部署节点，自动执行删除节点..."
        _delete_node_core "$state"
        remove_state
        rm -f "$LAST_LINKS_PATH" "$CF_ACCOUNT_PATH" "$ORIGIN_CERT_PATH" "$ORIGIN_KEY_PATH" "$ORIGIN_CSR_PATH"
    else
        # state 丢失也做云端残留清理 (v34 失败现场: CF 资源在云端但本地无账)
        info "未检测到 state, 按本地痕迹清理云端残留..."
        cleanup_orphan_residue
        rm -f "$LAST_LINKS_PATH" "$ORIGIN_CERT_PATH" "$ORIGIN_KEY_PATH" "$ORIGIN_CSR_PATH"
        remove_cfa_inbounds || true
    fi

    rm -rf "$STATE_DIR"
    rm -f /usr/local/bin/x

    local self
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    printf '\033[31m卸载完成，脚本文件已删除: %s\033[0m\n' "$self"
    rm -f -- "$self" 2>/dev/null || true
    exit 0
}

# ── 3. 查看节点 ──────────────────────────────────────
# 取节点链接：优先订阅快照，其次 state

print_node_links() {
    if [[ -f "$LAST_LINKS_PATH" ]]; then cat "$LAST_LINKS_PATH"; return; fi
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "无历史节点"
    echo "域名: $(echo "$state" | jq -r '.domain')"
    echo "UUID: $(echo "$state" | jq -r '.uuid')"
    echo "$state" | jq -r '.links | to_entries[] | "\(.key) \(.value)"'
}

# 生成优选订阅：调用第三方优选服务（节点信息会提交到该服务）


# ── 4. 修改配置 ──────────────────────────────────────
do_modify() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    local domain uid routes_json net_mode
    domain=$(echo "$state" | jq -r '.domain')
    uid=$(echo "$state" | jq -r '.uuid')
    routes_json=$(echo "$state" | jq '.routes')
    net_mode=$(echo "$state" | jq -r '.net_mode // "direct"')

    echo
    echo "当前配置 ($net_mode):"
    echo "  域名: $domain  UUID: $uid"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port)  CF端口:\(.cf_port)  路径:\(.path)"'
    echo
    echo "  1. 修改 UUID"
    echo "  2. 修改端口"
    echo "  3. 修改 WS 路径"
    echo "  4. 全部修改"
    echo "  0. 返回"
    echo
    read -rp "请选择 [0-4]: " mc

    local new_uid="$uid" new_routes="$routes_json" changed=false

    [[ "$mc" =~ ^[0-4]$ ]] || die "无效选项"
    [[ "$mc" == "0" ]] && return

    if [[ "$mc" == "1" || "$mc" == "4" ]]; then
        read -rp "新 UUID(留空=重新生成): " iu
        if [[ -n "$iu" ]]; then
            [[ "$iu" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式不正确"
            new_uid="${iu,,}"
        else
            new_uid=$(gen_uuid)
        fi
        changed=true; ok "UUID: $new_uid"
    fi

    if [[ "$mc" == "2" || "$mc" == "4" ]]; then
        local pc; pc=$(echo "$new_routes" | jq 'length')
        if [[ "$net_mode" == "nat" ]]; then
            echo "当前映射: $(echo "$new_routes" | jq -r '[.[] | "\(.listen_port):\(.cf_port)"] | join(",")')"
            read -rp "新端口映射(内部:外部，共${pc}组，留空=不改): " mr
            if [[ -n "$mr" ]]; then
                IFS=',' read -ra maps <<< "$mr"
                [[ ${#maps[@]} -eq $pc ]] || die "数量不匹配"
                local idx=0
                for m in "${maps[@]}"; do
                    m="${m// /}"; local lp="${m%%:*}" cp="${m##*:}"
                    [[ "$lp" =~ ^[0-9]+$ && "$cp" =~ ^[0-9]+$ ]] || die "无效: $m"
                    new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson l "$((lp))" --argjson c "$((cp))" '.[$i].listen_port=$l|.[$i].cf_port=$c')
                    idx=$((idx+1))
                done
                changed=true; ok "端口已更新"
            fi
        else
            echo "当前端口: $(echo "$new_routes" | jq -r '[.[].listen_port|tostring] | join(",")')"
            read -rp "新端口(逗号分隔，共${pc}个，留空=不改): " pr
            if [[ -n "$pr" ]]; then
                IFS=',' read -ra nps <<< "$pr"
                [[ ${#nps[@]} -eq $pc ]] || die "数量不匹配"
                local idx=0
                for np in "${nps[@]}"; do
                    np="${np// /}"; [[ "$np" =~ ^[0-9]+$ ]] || die "无效: $np"
                    new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson p "$((np))" '.[$i].listen_port=$p|.[$i].cf_port=$p')
                    idx=$((idx+1))
                done
                changed=true; ok "端口已更新"
            fi
        fi
    fi

    if [[ "$mc" == "3" || "$mc" == "4" ]]; then
        echo "当前路径: $(echo "$new_routes" | jq -r '[.[].path] | join(", ")')"
        read -rp "新 WS 路径前缀(留空=不改): " np
        if [[ -n "$np" ]]; then
            [[ "$np" == /* ]] || np="/${np}"
            new_routes=$(echo "$new_routes" | jq --arg pfx "$np" '[.[]|.path=($pfx+"-"+(if .protocol=="vless" then "vl" elif .protocol=="trojan" then "tr" else "vm" end))]')
            changed=true; ok "路径已更新"
        fi
    fi

    [[ "$changed" == "true" ]] || { echo "无修改"; return; }

    apply_cfa_inbounds "$(gen_cfa_inbounds "$new_routes" "$new_uid" "$(echo "$state" | jq -r '.ssl_mode // "flexible"')")"

    if load_cf_account; then
        apply_origin_rules "$(echo "$state" | jq -r '.zone_id')" "$domain" "$new_routes"
        ok "Origin Rules 已更新"
    fi

    local links_json; links_json=$(gen_all_links "$new_uid" "$domain" "$new_routes")
    save_links_snapshot "$domain" "$new_uid" "$links_json"
    save_state "$(echo "$state" | jq --arg u "$new_uid" --argjson r "$new_routes" --argjson l "$links_json" --arg s "${new_uid:0:8}" \
        '.uuid=$u|.short_id=$s|.routes=$r|.links=$l')"

    echo; ok "配置已更新"; print_links "$links_json"
}

# ── 5. 查看当前配置 ──────────────────────────────────
do_show_config() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    echo
    echo "域名:  $(echo "$state" | jq -r '.domain')"
    echo "UUID:  $(echo "$state" | jq -r '.uuid')"
    echo "模式:  $(echo "$state" | jq -r '.net_mode // "direct"')"
    echo "SSL:   $(echo "$state" | jq -r '.ssl_mode // "flexible"')"
    echo
    echo "入站:"
    echo "$state" | jq -r '.routes[] | "  \(.protocol)  监听:\(.listen_port)  CF端口:\(.cf_port)  路径:\(.path)"'
    echo
    echo -n "sing-box(主服务): "; svc_is_active && echo "运行中" || echo "未运行"
    echo
    echo "节点:"
    print_links "$(echo "$state" | jq '.links')"
    echo
}

# ── 6. 更新外部端口（NAT 快捷操作）──────────────────
do_update_ports() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    local domain routes_json net_mode
    domain=$(echo "$state" | jq -r '.domain')
    routes_json=$(echo "$state" | jq '.routes')
    net_mode=$(echo "$state" | jq -r '.net_mode // "direct"')

    echo
    echo "当前端口映射:"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port) -> 外部:\(.cf_port)"'
    echo

    local pc; pc=$(echo "$routes_json" | jq 'length')

    if [[ "$net_mode" == "nat" ]]; then
        info "NAT 模式: 只更新外部端口(CF Origin Rules)，本机监听端口不变"
        echo

        local new_routes="$routes_json" idx=0
        # 先把数据收进数组再循环：若用 `done < <(...)`，循环体的 stdin 会被数据流占用，
        # 里面的交互 read 会吃掉下一行数据。
        local rows=() row
        mapfile -t rows < <(echo "$routes_json" | jq -r '.[] | [.protocol, (.cf_port|tostring)] | @tsv')
        for row in "${rows[@]}"; do
            local proto="${row%%$'\t'*}" old_cp="${row##*$'\t'}" ne
            read -rp "${proto} 新外部端口(当前=${old_cp}): " ne
            [[ -n "$ne" ]] || die "不能为空"
            [[ "$ne" =~ ^[0-9]+$ ]] || die "无效端口: $ne"
            new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson p "$((ne))" '.[$i].cf_port=$p')
            idx=$((idx+1))
        done

        echo
        echo "更新预览:"
        echo "$new_routes" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port) -> 外部:\(.cf_port)"'
        read -rp "确认? (Y/n): " confirm
        [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

        # 只更新 CF Origin Rules，不动本机监听
        load_cf_account || die "未找到 CF 凭据"
        apply_origin_rules "$(echo "$state" | jq -r '.zone_id')" "$domain" "$new_routes"
        ok "Origin Rules 已更新"

        # 同时更新 DNS（公网 IP 可能也变了）
        local public_ip; public_ip=$(get_public_ip)
        local zone_id; zone_id=$(echo "$state" | jq -r '.zone_id')
        local current_dns; current_dns=$(cf_get_dns "$zone_id" "$domain")
        local current_ip; current_ip=$(echo "$current_dns" | jq -r '.content // ""')
        if [[ "$current_ip" != "$public_ip" ]]; then
            cf_upsert_dns "$zone_id" "$domain" "$public_ip" >/dev/null
            ok "DNS 已更新: $domain -> $public_ip"
        fi

        local uid; uid=$(echo "$state" | jq -r '.uuid')
        local links_json; links_json=$(gen_all_links "$uid" "$domain" "$new_routes")
        save_links_snapshot "$domain" "$uid" "$links_json"
        save_state "$(echo "$state" | jq --argjson r "$new_routes" --argjson l "$links_json" '.routes=$r|.links=$l')"

        echo; ok "外部端口已更新"; print_links "$links_json"
    else
        info "直连模式: 端口变更需要同时修改本机监听，请使用 [4.修改配置]"
    fi
}

# ── 6. 重启主服务 (CF-A 随主服务生效) ────────────────
# ── 8. 切换网络模式 ──────────────────────────────────
# 探测可能判错（issue #1），装完之后也得能改，否则只能卸载重装。
do_switch_net_mode() {
    local state; state=$(load_state 2>/dev/null || true)
    [[ -n "$state" ]] || die "未检测到部署"

    local domain zone_id uid cur routes_json
    domain=$(echo "$state" | jq -r '.domain')
    zone_id=$(echo "$state" | jq -r '.zone_id')
    uid=$(echo "$state" | jq -r '.uuid')
    cur=$(echo "$state" | jq -r '.net_mode // "direct"')
    routes_json=$(echo "$state" | jq '.routes')

    echo
    echo "当前模式: $(net_mode_label "$cur")"
    echo "$routes_json" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port)  外部:\(.cf_port)"'
    echo

    local target
    if [[ "$cur" == "nat" ]]; then
        target="direct"
        echo "切成直连后，对外端口将与本机监听端口一致。"
    else
        target="nat"
        echo "切成 NAT 后，需要为每个协议指定对外端口（路由器/宿主上映射到监听端口）。"
    fi
    read -rp "确认切换到 $(net_mode_label "$target")? (y/N): " c
    [[ "${c,,}" =~ ^(y|yes)$ ]] || die "已取消"

    local new_routes="$routes_json"
    if [[ "$target" == "direct" ]]; then
        # 直连下外部端口就是监听端口
        new_routes=$(echo "$new_routes" | jq '[.[] | .cf_port = .listen_port]')
    else
        local idx=0
        # 同上：先收进数组，别让数据流占住循环体的 stdin
        local rows=() row
        mapfile -t rows < <(echo "$routes_json" | jq -r '.[] | [.protocol, (.listen_port|tostring)] | @tsv')
        for row in "${rows[@]}"; do
            local proto="${row%%$'\t'*}" lp="${row##*$'\t'}" ep
            read -rp "${proto} 对外端口(监听=${lp}, 回车=相同): " ep
            [[ -n "$ep" ]] || ep="$lp"
            [[ "$ep" =~ ^[0-9]+$ ]] || die "无效端口: $ep"
            new_routes=$(echo "$new_routes" | jq --argjson i $idx --argjson p "$((ep))" '.[$i].cf_port=$p')
            idx=$((idx+1))
        done
    fi

    echo
    echo "更新预览:"
    echo "$new_routes" | jq -r '.[] | "  \(.protocol)  监听:\(.listen_port)  外部:\(.cf_port)"'
    read -rp "确认? (Y/n): " confirm
    [[ "${confirm,,}" =~ ^(|y|yes)$ ]] || die "已取消"

    load_cf_account || die "未找到 CF 凭据"
    apply_origin_rules "$zone_id" "$domain" "$new_routes"
    ok "Origin Rules 已更新"

    local links_json; links_json=$(gen_all_links "$uid" "$domain" "$new_routes")
    save_links_snapshot "$domain" "$uid" "$links_json"
    save_state "$(echo "$state" | jq --arg m "$target" --argjson r "$new_routes" --argjson l "$links_json" \
        '.net_mode=$m | .routes=$r | .links=$l')"

    echo; ok "已切换到 $(net_mode_label "$target")"; print_links "$links_json"
}

do_restart() {
    if ! svc_is_active; then
        echo "主 sing-box 当前未运行，正在启动..."
    else
        echo "正在重启主 sing-box 服务 (CF-A 节点随服务生效)..."
    fi
    restart_singbox
}

# ── 主入口 ────────────────────────────────────────────
ensure_shortcut() {
    local target="/usr/local/bin/x"
    # 已指向本仓库则跳过；否则（旧版/指向别处）一律重写，避免一直拉到旧脚本
    if [[ -f "$target" ]] && grep -q "XIEBROxzz/sx-cf-lite" "$target"; then
        return
    fi
    # 注意: 旧 target 可能是软链——直接 cat> 会顺着软链写脏目标文件, 必须先摘掉链接
    rm -f "$target"
    # POSIX 兼容的临时文件方式（避免 dash 不支持进程替换），保证任何发行版都能跑
    cat > "$target" << 'SCEOF'
#!/bin/sh
tmp=$(mktemp /tmp/sing-box-cf-lite.xXXXXXX) 2>/dev/null || exit 1
trap 'rm -f "$tmp"' EXIT
if ! curl -fsSL https://raw.githubusercontent.com/XIEBROxzz/sx-cf-lite/main/cf_lite.sh -o "$tmp" 2>/dev/null; then
    echo "下载主脚本失败，请检查网络后重试" >&2
    exit 1
fi
bash "$tmp" "$@"
SCEOF
    chmod +x "$target"
    ok "快捷命令 x 已更新指向本仓库"
}

# ── 旧版独立服务清理 ──────────────────────
# CF-A 已并入主 sing-box (cfa-* 入站 + 主服务)。检测到旧版独立 CF 服务
# (sing-box-cf / xray-cf) 时: 停用并移除其 unit, 节点由用户在 [1] 安装节点重走。
# 官方 xray.service (上游其他部署) 一律不碰。
_migrate_legacy_layout() {
    local u name
    for u in /etc/systemd/system/sing-box-cf.service /etc/systemd/system/xray-cf.service; do
        [ -f "$u" ] || continue
        name="$(basename "$u" .service)"
        info "检测到旧版独立 CF 服务: ${name} (CF-A 已并入主 sing-box), 停用并移除 unit..."
        systemctl stop "$name" &>/dev/null
        systemctl disable "$name" &>/dev/null
        rm -f "$u"
        systemctl daemon-reload &>/dev/null
        info "旧服务已移除; 如之前有旧节点, 请重新运行 [1. 安装节点]。"
    done
    local rc
    for rc in /etc/init.d/sing-box-cf /etc/init.d/xray-cf; do
        [ -f "$rc" ] || continue
        name="$(basename "$rc")"
        info "检测到旧版独立 CF 服务: ${name} (OpenRC), 停用并移除..."
        rc-service "$name" stop &>/dev/null
        rc-update del "$name" default &>/dev/null
        rm -f "$rc"
        info "旧服务已移除; 如之前有旧节点, 请重新运行 [1. 安装节点]。"
    done
    return 0
}

# WARP 接管重复实现已删除 —— CF-A 节点并入主 sing-box 后,
# relay.json 的 WARP/中转/落地规则 (全局规则, 不绑 inboundTag) 对 CF-A 天然生效,
# 统一在主菜单 [18] 的 WARP 管理里操作, 此处不再单独维护一份。
main() {
    [[ "$(id -u)" == "0" ]] || die "请使用 root 运行此脚本"
    detect_init
    _migrate_legacy_layout

    # ── SX: 无头模式 (供 sx 主菜单 [4]/[17] 直调, 不进交互菜单) ──
    case "${1:-}" in
        delete)
            install_deps >/dev/null 2>&1
            command -v jq &>/dev/null || die "缺少依赖: jq"
            do_delete_node
            return 0 ;;
        status)
            load_state 2>/dev/null || echo '{}'
            return 0 ;;
        links)
            print_node_links
            return 0 ;;
    esac

    install_deps
    need_cmd curl; need_cmd jq
    ensure_shortcut

    local state current_domain="" net_mode=""
    state=$(load_state 2>/dev/null || true)
    if [[ -n "$state" ]]; then
        current_domain=$(echo "$state" | jq -r '.domain // ""')
        net_mode=$(echo "$state" | jq -r '.net_mode // ""')
    fi

    echo
    echo "  sing-box-cf-lite ($INIT_SYSTEM) —— CF-A 并入主 sing-box"
    echo
    echo "  1. 安装节点"
    echo "  2. 删除节点"
    echo "  3. 修改配置(UUID/端口/路径)"
    echo "  4. 查看当前配置"
    echo "  5. 更新外部端口(NAT换端口)"
    echo "  6. 重启主 sing-box 服务"
    echo "  7. 切换网络模式(直连/NAT)"
    echo "  (WARP 接管 / 中转规则: 主菜单统一管理, 对 CF-A 同样生效)"
    [[ -n "$current_domain" ]] && echo "     (当前: $current_domain${net_mode:+ [$net_mode]})"
    echo
    echo -e "  \033[31m  0. 返回主菜单\033[0m"
    echo

    read -rp "请选择 [0-7]: " choice
    case "$choice" in
        1) do_install ;; 2) do_delete_node ;; 3) do_modify ;; 4) do_show_config ;;
        5) do_update_ports ;; 6) do_restart ;; 7) do_switch_net_mode ;;
        0) exit 0 ;;
        *) die "无效选择: $choice" ;;
    esac
}
main "$@"




