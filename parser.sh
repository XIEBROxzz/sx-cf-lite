#!/bin/bash

# 第三方落地节点的严格解析器。
# 正常调用方式：printf '%s\n' "$link" | bash parser.sh MODE
# 第二个参数仅保留给测试使用，生产调用不要把凭据放入进程参数。
# ┌─ 文件说明（配置地基）─────────────────────────────
# │ parser.sh = 第三方分享链接严格解析器 (无状态工具, 不持有任何地基文件)
# │ v1.0: auto 模式错误契约 (复查 error 对象重抛 rc=1, 消除"不符合 schema"误报);
# │       hy2 现实兼容 (无 sni 回退 / obfs=none / 大小写协议头 / 多余参数与空白容忍)
# └───────────────────────────────────────────────

umask 077
export LC_ALL=C

DECODED_VALUE=""
NORMALIZED_PORT=""
GROUP_COUNT=0
PARSED_SERVER=""
PARSED_PORT=""
VLESS_UUID=""
VLESS_SERVER=""
VLESS_PORT=""
LINK_INPUT=""

declare -A QUERY_PARAMS=()
declare -A QUERY_PRESENT=()

_json_escape() {
    local escaped
    escaped="$1"
    escaped="${escaped//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    escaped="${escaped//$'\r'/\\r}"
    escaped="${escaped//$'\n'/\\n}"
    escaped="${escaped//$'\t'/\\t}"
    printf '%s' "$escaped"
}

_fatal() {
    local message escaped
    message="$1"
    escaped=$(_json_escape "$message")
    printf '{"error":"%s"}\n' "$escaped"
    exit 1
}

_url_decode() {
    local input plus_as_space decoded char hex
    input="$1"
    plus_as_space="${2:-0}"
    decoded=""

    while [[ -n "$input" ]]; do
        char="${input:0:1}"
        case "$char" in
            '%')
                (( ${#input} >= 3 )) || return 1
                hex="${input:1:2}"
                [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]] || return 1
                [[ "$hex" != "00" ]] || return 1
                printf -v char '%b' "\\x${hex}"
                decoded+="$char"
                input="${input:3}"
                ;;
            '+')
                if [[ "$plus_as_space" == "1" ]]; then
                    decoded+=' '
                else
                    decoded+='+'
                fi
                input="${input:1}"
                ;;
            *)
                decoded+="$char"
                input="${input:1}"
                ;;
        esac
    done

    DECODED_VALUE="$decoded"
}

_decode_base64_urlsafe() {
    local input normalized core padding existing_padding needed_padding decoded
    input="$1"
    [[ -n "$input" ]] || return 1
    [[ "$input" =~ ^[A-Za-z0-9+/_-]+={0,2}$ ]] || return 1

    normalized="${input//-/+}"
    normalized="${normalized//_/\/}"
    core="${normalized%%=*}"
    padding="${normalized:${#core}}"
    existing_padding=${#padding}

    case $(( ${#core} % 4 )) in
        0) needed_padding=0 ;;
        2) needed_padding=2 ;;
        3) needed_padding=1 ;;
        *) return 1 ;;
    esac

    if (( existing_padding != 0 && existing_padding != needed_padding )); then
        return 1
    fi

    normalized="$core"
    while (( ${#normalized} % 4 != 0 )); do
        normalized+='='
    done

    if ! decoded=$(printf '%s' "$normalized" | base64 -d 2>/dev/null); then
        return 1
    fi
    [[ -n "$decoded" ]] || return 1
    [[ "$decoded" != *$'\r'* && "$decoded" != *$'\n'* ]] || return 1
    DECODED_VALUE="$decoded"
}

_validate_ss2022_key() {
    local key="$1" expected_bytes="$2" pattern decoded_bytes
    case "$expected_bytes" in
        16) pattern='^[A-Za-z0-9+/]{22}==$' ;;
        32) pattern='^[A-Za-z0-9+/]{43}=$' ;;
        *) return 1 ;;
    esac
    [[ "$key" =~ $pattern ]] || return 1
    decoded_bytes=$(set -o pipefail; printf '%s' "$key" | base64 -d 2>/dev/null | wc -c) || return 1
    [[ "$decoded_bytes" -eq "$expected_bytes" ]]
}

_validate_ss2022_password() {
    local password="$1" method="$2" expected_bytes server_key user_key
    case "$method" in
        2022-blake3-aes-128-gcm) expected_bytes=16 ;;
        2022-blake3-aes-256-gcm) expected_bytes=32 ;;
        *) return 1 ;;
    esac
    server_key="$password"
    if [[ "$password" == *:* ]]; then
        [[ "$password" != *:*:* ]] || return 1
        server_key="${password%%:*}"
        user_key="${password#*:}"
        _validate_ss2022_key "$user_key" "$expected_bytes" || return 1
    fi
    _validate_ss2022_key "$server_key" "$expected_bytes"
}

_normalize_port() {
    local raw value
    raw="$1"
    [[ "$raw" =~ ^[0-9]+$ ]] || return 1
    (( ${#raw} <= 5 )) || return 1
    value=$((10#$raw))
    (( value >= 1 && value <= 65535 )) || return 1
    NORMALIZED_PORT="$value"
}

_validate_ipv4() {
    local address octet value
    local -a octets
    address="$1"
    [[ "$address" != .* && "$address" != *. && "$address" != *..* ]] || return 1
    IFS='.' read -r -a octets <<< "$address"
    (( ${#octets[@]} == 4 )) || return 1

    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        value=$((10#$octet))
        (( value <= 255 )) || return 1
    done
}

_count_ipv6_groups() {
    local part group
    local -a groups
    part="$1"
    GROUP_COUNT=0
    [[ -n "$part" ]] || return 0
    [[ "$part" != :* && "$part" != *: ]] || return 1
    IFS=':' read -r -a groups <<< "$part"
    for group in "${groups[@]}"; do
        [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
    GROUP_COUNT=${#groups[@]}
}

_validate_ipv6() {
    local address ipv4_tail prefix left right after_first
    local left_count right_count
    address="$1"
    [[ "$address" == *:* ]] || return 1
    [[ "$address" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1

    if [[ "$address" == *.* ]]; then
        ipv4_tail="${address##*:}"
        _validate_ipv4 "$ipv4_tail" || return 1
        prefix="${address%:*}"
        address="${prefix}:0:0"
    fi

    if [[ "$address" == *::* ]]; then
        after_first="${address#*::}"
        [[ "$after_first" != *::* ]] || return 1
        left="${address%%::*}"
        right="$after_first"
        _count_ipv6_groups "$left" || return 1
        left_count=$GROUP_COUNT
        _count_ipv6_groups "$right" || return 1
        right_count=$GROUP_COUNT
        (( left_count + right_count < 8 )) || return 1
    else
        [[ "$address" != :* && "$address" != *: ]] || return 1
        _count_ipv6_groups "$address" || return 1
        (( GROUP_COUNT == 8 )) || return 1
    fi
}

_validate_hostname() {
    local hostname label
    local -a labels
    hostname="$1"
    (( ${#hostname} >= 1 && ${#hostname} <= 253 )) || return 1
    [[ "$hostname" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$hostname" != .* && "$hostname" != *. && "$hostname" != *..* ]] || return 1

    IFS='.' read -r -a labels <<< "$hostname"
    for label in "${labels[@]}"; do
        (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

_validate_server() {
    local server
    server="$1"
    [[ -n "$server" ]] || return 1
    [[ "$server" != *[$'\t\r\n /?#@']* ]] || return 1

    if [[ "$server" == *:* ]]; then
        _validate_ipv6 "$server"
    elif [[ "$server" =~ ^[0-9.]+$ && "$server" == *.* ]]; then
        _validate_ipv4 "$server"
    else
        _validate_hostname "$server"
    fi
}

_split_host_port() {
    local endpoint
    endpoint="$1"
    PARSED_SERVER=""
    PARSED_PORT=""

    if [[ "$endpoint" =~ ^\[([^][]+)\]:([0-9]+)$ ]]; then
        PARSED_SERVER="${BASH_REMATCH[1]}"
        PARSED_PORT="${BASH_REMATCH[2]}"
    elif [[ "$endpoint" =~ ^([^:]+):([0-9]+)$ ]]; then
        PARSED_SERVER="${BASH_REMATCH[1]}"
        PARSED_PORT="${BASH_REMATCH[2]}"
    else
        return 1
    fi

    _validate_server "$PARSED_SERVER" || return 1
    _normalize_port "$PARSED_PORT" || return 1
    PARSED_PORT="$NORMALIZED_PORT"
}

_parse_query() {
    local query pair raw_key raw_value key value
    local -a pairs
    query="$1"
    QUERY_PARAMS=()
    QUERY_PRESENT=()
    [[ -n "$query" ]] || return 0

    IFS='&' read -r -a pairs <<< "$query"
    for pair in "${pairs[@]}"; do
        [[ -n "$pair" ]] || return 1
        raw_key="${pair%%=*}"
        if [[ "$pair" == *=* ]]; then
            raw_value="${pair#*=}"
        else
            raw_value=""
        fi

        _url_decode "$raw_key" 1 || return 1
        key="$DECODED_VALUE"
        _url_decode "$raw_value" 1 || return 1
        value="$DECODED_VALUE"
        [[ "$key" =~ ^[A-Za-z0-9._~-]+$ ]] || return 1
        [[ -z "${QUERY_PRESENT[$key]+x}" ]] || return 1
        QUERY_PRESENT["$key"]=1
        QUERY_PARAMS["$key"]="$value"
    done
}

_require_query_keys() {
    local allowed key
    allowed=" $* "
    for key in "${!QUERY_PRESENT[@]}"; do
        [[ "$allowed" == *" $key "* ]] || _fatal "节点链接包含当前模式不支持的查询参数"
    done
}

_parse_vless_uri() {
    local link body authority query raw_uuid endpoint
    link="$1"
    [[ "$link" == vless://* ]] || _fatal "链接必须以 vless:// 开头"
    body="${link#vless://}"
    body="${body%%#*}"
    [[ -n "$body" ]] || _fatal "VLESS 链接为空"

    if [[ "$body" == *\?* ]]; then
        authority="${body%%\?*}"
        query="${body#*\?}"
    else
        authority="$body"
        query=""
    fi

    [[ "$authority" == *@* ]] || _fatal "VLESS 链接缺少 UUID 或服务器地址"
    raw_uuid="${authority%%@*}"
    endpoint="${authority#*@}"
    [[ "$endpoint" != *@* ]] || _fatal "VLESS 链接的服务器地址格式错误"
    _url_decode "$raw_uuid" 0 || _fatal "VLESS UUID 包含无效 URL 编码"
    VLESS_UUID="$DECODED_VALUE"
    [[ "$VLESS_UUID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || _fatal "VLESS UUID 格式无效"

    _split_host_port "$endpoint" || _fatal "VLESS 服务器地址或端口无效"
    VLESS_SERVER="$PARSED_SERVER"
    VLESS_PORT="$PARSED_PORT"
    _parse_query "$query" || _fatal "VLESS 查询参数格式无效或包含重复参数"
}

_require_tcp_transport() {
    local transport header_type encryption
    transport="${QUERY_PARAMS[type]-}"
    header_type="${QUERY_PARAMS[headerType]-}"
    encryption="${QUERY_PARAMS[encryption]-}"
    [[ -z "$transport" || "$transport" == "tcp" ]] || _fatal "仅支持 VLESS TCP 节点"
    [[ -z "$header_type" || "$header_type" == "none" ]] || _fatal "VLESS TCP 不支持额外头部伪装"
    [[ -z "$encryption" || "$encryption" == "none" ]] || _fatal "VLESS encryption 必须为 none"
}

_parse_vless_reality_vision() {
    local link security flow sni public_key short_id fingerprint output
    link="$1"
    _parse_vless_uri "$link"
    _require_query_keys encryption flow security sni servername fp pbk sid type headerType
    _require_tcp_transport

    security="${QUERY_PARAMS[security]-}"
    flow="${QUERY_PARAMS[flow]-}"
    sni="${QUERY_PARAMS[sni]-}"
    [[ -n "$sni" ]] || sni="${QUERY_PARAMS[servername]-}"
    public_key="${QUERY_PARAMS[pbk]-}"
    short_id="${QUERY_PARAMS[sid]-}"
    fingerprint="${QUERY_PARAMS[fp]-chrome}"

    [[ "$security" == "reality" ]] || _fatal "Reality 节点的 security 必须为 reality"
    [[ "$flow" == "xtls-rprx-vision" ]] || _fatal "Reality 节点的 flow 必须为 xtls-rprx-vision"
    _validate_server "$sni" || _fatal "Reality 节点缺少有效的 SNI"
    [[ "$public_key" =~ ^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$ ]] || _fatal "Reality 公钥 pbk 格式无效"
    [[ "$short_id" =~ ^[0-9A-Fa-f]{0,16}$ && $(( ${#short_id} % 2 )) -eq 0 ]] || _fatal "Reality short id 必须是长度不超过 16 的偶数位十六进制字符串"
    case "$fingerprint" in
        chrome|firefox|edge|safari|360|qq|ios|android|random|randomized) ;;
        *) _fatal "Reality uTLS 指纹不在 sing-box 支持列表中" ;;
    esac

    if ! output=$(jq -n \
        --arg server "$VLESS_SERVER" \
        --argjson port "$VLESS_PORT" \
        --arg uuid "$VLESS_UUID" \
        --arg sni "$sni" \
        --arg public_key "$public_key" \
        --arg short_id "$short_id" \
        --arg fingerprint "$fingerprint" \
        '{type:"vless",tag:"proxy",server:$server,server_port:$port,uuid:$uuid,network:"tcp",flow:"xtls-rprx-vision",tls:{enabled:true,server_name:$sni,reality:{enabled:true,public_key:$public_key,short_id:$short_id},utls:{enabled:true,fingerprint:$fingerprint}}}'); then
        _fatal "生成 VLESS + TCP + Reality + Vision outbound 失败"
    fi
    printf '%s\n' "$output"
}

_parse_vless_tcp() {
    local link security output
    link="$1"
    _parse_vless_uri "$link"
    _require_query_keys encryption security type headerType
    _require_tcp_transport

    security="${QUERY_PARAMS[security]-}"
    [[ -z "$security" || "$security" == "none" ]] || _fatal "纯 VLESS TCP 节点不能启用 TLS 或 Reality"

    if ! output=$(jq -n \
        --arg server "$VLESS_SERVER" \
        --argjson port "$VLESS_PORT" \
        --arg uuid "$VLESS_UUID" \
        '{type:"vless",tag:"proxy",server:$server,server_port:$port,uuid:$uuid,network:"tcp"}'); then
        _fatal "生成纯 VLESS TCP outbound 失败"
    fi
    printf '%s\n' "$output"
}

_parse_vless_ws_tls() {
    local link security transport sni host path fingerprint insecure_raw insecure output
    link="$1"
    _parse_vless_uri "$link"
    _require_query_keys encryption flow security sni servername fp insecure allowInsecure host path alpn ed headerType type

    security="${QUERY_PARAMS[security]-}"
    transport="${QUERY_PARAMS[type]-}"
    [[ "$security" == "tls" ]] || _fatal "VLESS-WS-TLS 节点的 security 必须为 tls"
    [[ "$transport" == "ws" ]] || _fatal "VLESS-WS-TLS 节点的 type 必须为 ws"

    local encryption="${QUERY_PARAMS[encryption]-}"
    [[ -z "$encryption" || "$encryption" == "none" ]] || _fatal "VLESS encryption 必须为 none"

    local flow="${QUERY_PARAMS[flow]-}"
    [[ -z "$flow" ]] || _fatal "VLESS WebSocket 节点不能启用 flow"

    local header_type="${QUERY_PARAMS[headerType]-}"
    [[ -z "$header_type" || "$header_type" == "none" ]] || _fatal "VLESS WS 不支持额外头部伪装"

    sni="${QUERY_PARAMS[sni]-}"
    [[ -n "$sni" ]] || sni="${QUERY_PARAMS[servername]-}"
    [[ -n "$sni" ]] || sni="$VLESS_SERVER"
    _validate_server "$sni" || _fatal "VLESS-WS-TLS 节点缺少有效的 SNI 或服务器域名"

    host="${QUERY_PARAMS[host]-}"
    [[ -n "$host" ]] || host="$sni"
    _validate_server "$host" || _fatal "VLESS-WS-TLS 节点的 host 格式无效"

    path="${QUERY_PARAMS[path]-}"
    [[ -n "$path" ]] || path="/"
    [[ "$path" == /* ]] || path="/${path}"
    # SX修复: 剥离 path 内 query (?ed=2560 等) —— sing-box 不解析 ed 参数, 原样发送会 404
    local ws_query="" early_json="{}"
    if [[ "$path" == *\?* ]]; then
        ws_query="${path#*\?}"
        path="${path%%\?*}"
        if [[ "$ws_query" =~ (^|&)ed=([0-9]+) ]]; then
            early_json=$(jq -nc --argjson ed "${BASH_REMATCH[2]}" '{max_early_data:$ed,early_data_header_name:"Sec-WebSocket-Protocol"}')
        fi
    fi
    [[ -n "$path" && "$path" == /* ]] || path="/"

    fingerprint="${QUERY_PARAMS[fp]-chrome}"
    case "$fingerprint" in
        chrome|firefox|edge|safari|360|qq|ios|android|random|randomized) ;;
        *) _fatal "uTLS 指纹不在 sing-box 支持列表中" ;;
    esac

    insecure_raw="${QUERY_PARAMS[insecure]-}"
    [[ -n "$insecure_raw" ]] || insecure_raw="${QUERY_PARAMS[allowInsecure]-0}"
    if [[ "$insecure_raw" == "1" || "$insecure_raw" == "true" ]]; then
        insecure=true
    else
        insecure=false
    fi

    if ! output=$(jq -n \
        --arg server "$VLESS_SERVER" \
        --argjson port "$VLESS_PORT" \
        --arg uuid "$VLESS_UUID" \
        --arg sni "$sni" \
        --arg host "$host" \
        --arg path "$path" \
        --arg fingerprint "$fingerprint" \
        --argjson insecure "$insecure" \
        --argjson early "$early_json" \
        '{type:"vless",tag:"proxy",server:$server,server_port:$port,uuid:$uuid,network:"tcp",tls:{enabled:true,server_name:$sni,insecure:$insecure,utls:{enabled:true,fingerprint:$fingerprint}},transport:({type:"ws",path:$path,headers:{Host:$host}} + $early)}'); then
        _fatal "生成 VLESS + WebSocket + TLS outbound 失败"
    fi
    printf '%s\n' "$output"
}

_parse_ss_uri() {
    local link expected_method body main query raw_userinfo endpoint decoded method_password
    local method password output key
    link="$1"
    expected_method="$2"
    [[ "$link" == ss://* ]] || _fatal "链接必须以 ss:// 开头"
    body="${link#ss://}"
    body="${body%%#*}"
    [[ -n "$body" ]] || _fatal "Shadowsocks 链接为空"

    if [[ "$body" == *\?* ]]; then
        main="${body%%\?*}"
        query="${body#*\?}"
    else
        main="$body"
        query=""
    fi

    if [[ -n "$query" ]]; then
        _parse_query "$query" || _fatal "Shadowsocks 查询参数格式无效"
        for key in "${!QUERY_PRESENT[@]}"; do
            [[ "${key,,}" != "plugin" ]] || _fatal "不支持带 plugin 的 Shadowsocks 节点"
        done
        _fatal "Shadowsocks 链接包含不支持的查询参数"
    fi

    if [[ "$main" == *@* ]]; then
        raw_userinfo="${main%@*}"
        endpoint="${main##*@}"
        endpoint="${endpoint%/}"
        [[ -n "$raw_userinfo" && -n "$endpoint" ]] || _fatal "Shadowsocks 链接格式无效"

        _url_decode "$raw_userinfo" 0 || _fatal "Shadowsocks 凭据包含无效 URL 编码"
        decoded="$DECODED_VALUE"
        if [[ "$decoded" == *:* ]]; then
            method_password="$decoded"
        else
            _decode_base64_urlsafe "$decoded" || _fatal "Shadowsocks SIP002 凭据 Base64 解码失败"
            method_password="$DECODED_VALUE"
        fi
    else
        _decode_base64_urlsafe "$main" || _fatal "Shadowsocks 整串 Base64 解码失败"
        decoded="$DECODED_VALUE"
        [[ "$decoded" == *@* ]] || _fatal "Shadowsocks 整串 Base64 内容格式无效"
        method_password="${decoded%@*}"
        endpoint="${decoded##*@}"
    fi

    [[ "$method_password" == *:* ]] || _fatal "Shadowsocks 链接缺少加密方法或密码"
    method="${method_password%%:*}"
    password="${method_password#*:}"
    [[ "$method" == "$expected_method" ]] || _fatal "Shadowsocks 链接的加密方法与所选类型不一致"
    [[ -n "$password" ]] || _fatal "Shadowsocks 密码不能为空"
    [[ "$password" != *$'\r'* && "$password" != *$'\n'* ]] || _fatal "Shadowsocks 密码包含无效控制字符"
    if [[ "$method" == 2022-blake3-* ]]; then
        _validate_ss2022_password "$password" "$method" || _fatal "SS2022 密钥必须是符合所选 AES 算法长度的 Base64（单密钥或服务端密钥:用户密钥）"
    fi

    _split_host_port "$endpoint" || _fatal "Shadowsocks 服务器地址或端口无效"
    if ! output=$(jq -n \
        --arg server "$PARSED_SERVER" \
        --argjson port "$PARSED_PORT" \
        --arg method "$method" \
        --arg password "$password" \
        '{type:"shadowsocks",tag:"proxy",server:$server,server_port:$port,method:$method,password:$password}'); then
        _fatal "生成 Shadowsocks outbound 失败"
    fi
    printf '%s\n' "$output"
}

_parse_http_uri() {
    local link body authority userinfo endpoint raw_user raw_pass username password
    local use_tls=true default_port=443 output
    link="$1"

    if [[ "$link" == http://* ]]; then
        use_tls=false
        default_port=80
        body="${link#http://}"
    elif [[ "$link" == https://* ]]; then
        use_tls=true
        default_port=443
        body="${link#https://}"
    else
        use_tls=true
        default_port=443
        body="$link"
    fi

    body="${body%%#*}"
    local query="" authority="$body"
    if [[ "$body" == *\?* ]]; then
        authority="${body%%\?*}"
        query="${body#*\?}"
    fi
    [[ -n "$authority" ]] || _fatal "HTTP 代理地址为空"

    username=""
    password=""
    if [[ "$authority" == *@* ]]; then
        userinfo="${authority%@*}"
        endpoint="${authority##*@}"
        [[ -n "$userinfo" && -n "$endpoint" ]] || _fatal "HTTP 代理链接格式无效"
        raw_user="${userinfo%%:*}"
        if [[ "$userinfo" == *:* ]]; then
            raw_pass="${userinfo#*:}"
        else
            raw_pass=""
        fi
        _url_decode "$raw_user" 0 || _fatal "HTTP 用户名 URL 解码失败"
        username="$DECODED_VALUE"
        _url_decode "$raw_pass" 0 || _fatal "HTTP 密码 URL 解码失败"
        password="$DECODED_VALUE"
    else
        endpoint="$authority"
    fi

    endpoint="${endpoint%/}"
    if [[ "$endpoint" == *:* ]]; then
        _split_host_port "$endpoint" || _fatal "HTTP 服务器地址或端口无效"
    else
        _validate_server "$endpoint" || _fatal "HTTP 服务器地址无效"
        PARSED_SERVER="$endpoint"
        PARSED_PORT="$default_port"
    fi

    local sni="" insecure=false
    if [[ -n "$query" ]]; then
        _parse_query "$query" || _fatal "HTTP 代理查询参数格式无效或包含重复参数"
        _require_query_keys "sni" "peer" "insecure" "allowInsecure"
        sni="${QUERY_PARAMS[sni]-}"
        [[ -n "$sni" ]] || sni="${QUERY_PARAMS[peer]-}"
        local insec="${QUERY_PARAMS[insecure]-}"
        [[ -n "$insec" ]] || insec="${QUERY_PARAMS[allowInsecure]-}"
        if [[ "$insec" == "1" || "$insec" == "true" ]]; then
            insecure=true
        elif [[ -n "$insec" && "$insec" != "0" && "$insec" != "false" ]]; then
            _fatal "HTTP 代理 insecure 参数值无效"
        fi
    fi

    if [[ "$use_tls" == "true" ]]; then
        if [[ -z "$sni" ]]; then
            sni="$PARSED_SERVER"
        else
            _validate_server "$sni" || _fatal "HTTP 代理 SNI 地址无效"
        fi
        if [[ -n "$username" || -n "$password" ]]; then
            output=$(jq -n \
                --arg server "$PARSED_SERVER" \
                --argjson port "$PARSED_PORT" \
                --arg user "$username" \
                --arg pass "$password" \
                --arg sni "$sni" \
                --argjson insecure "$insecure" \
                '{type:"http",tag:"proxy",server:$server,server_port:$port,username:$user,password:$pass,tls:{enabled:true,server_name:$sni,insecure:$insecure}}')
        else
            output=$(jq -n \
                --arg server "$PARSED_SERVER" \
                --argjson port "$PARSED_PORT" \
                --arg sni "$sni" \
                --argjson insecure "$insecure" \
                '{type:"http",tag:"proxy",server:$server,server_port:$port,tls:{enabled:true,server_name:$sni,insecure:$insecure}}')
        fi
    else
        if [[ -n "$username" || -n "$password" ]]; then
            output=$(jq -n \
                --arg server "$PARSED_SERVER" \
                --argjson port "$PARSED_PORT" \
                --arg user "$username" \
                --arg pass "$password" \
                '{type:"http",tag:"proxy",server:$server,server_port:$port,username:$user,password:$pass}')
        else
            output=$(jq -n \
                --arg server "$PARSED_SERVER" \
                --argjson port "$PARSED_PORT" \
                '{type:"http",tag:"proxy",server:$server,server_port:$port}')
        fi
    fi

    if [[ -z "$output" ]]; then
        _fatal "生成 HTTP/HTTPS outbound 失败"
    fi
    printf '%s\n' "$output"
}

# SX: Hysteria2 链接解析 (hysteria2:// 或 hy2://)
_parse_hysteria2_uri() {
    local link body authority query password endpoint server port
    local sni insecure obfs obfs_password pin output obfs_json
    link="$1"
    case "$link" in
        hysteria2://*) body="${link#hysteria2://}" ;;
        hy2://*) body="${link#hy2://}" ;;
        *) _fatal "链接必须以 hysteria2:// 或 hy2:// 开头" ;;
    esac
    body="${body%%#*}"
    [[ -n "$body" ]] || _fatal "Hysteria2 链接为空"

    if [[ "$body" == *\?* ]]; then
        authority="${body%%\?*}"
        query="${body#*\?}"
    else
        authority="$body"
        query=""
    fi
    authority="${authority%/}"   # 兼容 v2 风格 hysteria2://pw@host:443/?sni=... (query 前多一个 "/")
    [[ -n "$authority" ]] || _fatal "Hysteria2 链接的服务器地址为空"

    [[ "$authority" == *@* ]] || _fatal "Hysteria2 链接缺少密码或服务器地址"
    password="${authority%%@*}"
    endpoint="${authority#*@}"
    [[ "$endpoint" != *@* ]] || _fatal "Hysteria2 链接的服务器地址格式错误"
    _url_decode "$password" 0 || _fatal "Hysteria2 密码包含无效 URL 编码"
    password="$DECODED_VALUE"
    [[ -n "$password" && "$password" != *[[:space:]]* ]] || _fatal "Hysteria2 密码格式无效"

    _split_host_port "$endpoint" || _fatal "Hysteria2 服务器地址或端口无效"
    server="$PARSED_SERVER"
    port="$PARSED_PORT"
    _parse_query "$query" || _fatal "Hysteria2 查询参数格式无效或包含重复参数"
    # 不再对未知查询参数整体拒绝 —— 真实分享链接常带 up/down、fastOpen、lazy 等
    # 客户端附带参数, 与生成的 outbound 无关, 一律忽略 (此前整体拒绝是 "不符合 schema" 主因之一)
    sni="${QUERY_PARAMS[sni]-}"
    insecure="${QUERY_PARAMS[insecure]-}"
    obfs="${QUERY_PARAMS[obfs]-}"
    obfs_password="${QUERY_PARAMS[obfs-password]-}"
    pin="${QUERY_PARAMS[pinSHA256]-}"
    [[ "$obfs" != "none" ]] || obfs=""   # 兼容 obfs=none (未启用混淆)

    if [[ -z "$sni" ]]; then
        # 无 sni —— 与常见客户端一致的回退: SNI 默认取服务器地址(sing-box 缺省行为同)
        sni="$PARSED_SERVER"
        [[ "$insecure" == "1" ]] || _fatal "Hysteria2 节点缺少 sni 参数 ( insecure=0 时必须提供 SNI )"
    fi
    _validate_server "$sni" || _fatal "Hysteria2 SNI 无效"
    case "$insecure" in
        ""|0) insecure="false" ;;
        1) insecure="true" ;;
        *) _fatal "Hysteria2 insecure 参数仅允许 0 或 1" ;;
    esac
    if [[ -n "$pin" ]]; then
        [[ "$pin" =~ ^[0-9A-Fa-f]{64}$ ]] || _fatal "Hysteria2 pinSHA256 必须为 64 位十六进制"
        # SX: insecure=1 时丢弃 pin —— sing-box 设置 pin 后强制校验(即使 insecure), 自签证书轮换会失配
        [[ "$insecure" == "true" ]] && pin=""
    fi

    obfs_json="null"
    if [[ -n "$obfs" ]]; then
        [[ "$obfs" == "salamander" ]] || _fatal "Hysteria2 仅支持 salamander 混淆"
        [[ -n "$obfs_password" ]] || _fatal "Hysteria2 salamander 混淆缺少 obfs-password"
        obfs_json=$(jq -nc --arg pw "$obfs_password" '{type:"salamander",password:$pw}')
    fi

    if ! output=$(jq -nc \
        --arg server "$server" \
        --argjson port "$port" \
        --arg password "$password" \
        --arg sni "$sni" \
        --argjson insecure "$insecure" \
        --argjson obfs "$obfs_json" \
        --arg pin "$pin" \
        '{type:"hysteria2",tag:"proxy",server:$server,server_port:$port,password:$password}
            + (if $obfs != null then {obfs:$obfs} else {} end)
            + {tls:({enabled:true,server_name:$sni,insecure:$insecure,alpn:["h3"]}
                + (if $pin != "" then {certificate_public_key_sha256:$pin} else {} end))}'); then
        _fatal "生成 Hysteria2 outbound 失败"
    fi
    printf '%s\n' "$output"
}

# SX: TUICv5 链接解析
_parse_tuic_uri() {
    local link body authority query userinfo uuid password endpoint server port
    local sni alpn cc ur insecure output alpn_json
    link="$1"
    [[ "$link" == tuic://* ]] || _fatal "链接必须以 tuic:// 开头"
    body="${link#tuic://}"
    body="${body%%#*}"
    [[ -n "$body" ]] || _fatal "TUIC 链接为空"

    if [[ "$body" == *\?* ]]; then
        authority="${body%%\?*}"
        query="${body#*\?}"
    else
        authority="$body"
        query=""
    fi

    [[ "$authority" == *@* ]] || _fatal "TUIC 链接缺少凭据或服务器地址"
    userinfo="${authority%%@*}"
    endpoint="${authority#*@}"
    [[ "$endpoint" != *@* ]] || _fatal "TUIC 链接的服务器地址格式错误"
    [[ "$userinfo" == *:* ]] || _fatal "TUIC 链接缺少 uuid:password 凭据"
    uuid="${userinfo%%:*}"
    password="${userinfo#*:}"
    [[ -n "$password" ]] || _fatal "TUIC 密码为空"
    [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || _fatal "TUIC UUID 格式无效"

    _split_host_port "$endpoint" || _fatal "TUIC 服务器地址或端口无效"
    server="$PARSED_SERVER"
    port="$PARSED_PORT"
    _parse_query "$query" || _fatal "TUIC 查询参数格式无效或包含重复参数"
    _require_query_keys sni alpn congestion_control udp_relay_mode allow_insecure allowInsecure

    sni="${QUERY_PARAMS[sni]-}"
    alpn="${QUERY_PARAMS[alpn]-h3}"
    cc="${QUERY_PARAMS[congestion_control]-bbr}"
    ur="${QUERY_PARAMS[udp_relay_mode]-native}"
    insecure="${QUERY_PARAMS[allow_insecure]-${QUERY_PARAMS[allowInsecure]-}}"

    [[ -n "$sni" ]] || _fatal "TUIC 节点缺少 sni 参数"
    _validate_server "$sni" || _fatal "TUIC SNI 无效"
    case "$insecure" in
        ""|0) insecure="false" ;;
        1) insecure="true" ;;
        *) _fatal "TUIC allow_insecure 参数仅允许 0 或 1" ;;
    esac
    case "$cc" in bbr|cubic|new_reno) ;; *) _fatal "TUIC congestion_control 仅支持 bbr/cubic/new_reno" ;; esac
    case "$ur" in native|quic) ;; *) _fatal "TUIC udp_relay_mode 仅支持 native/quic" ;; esac
    alpn_json=$(printf '%s' "$alpn" | tr ',' '\n' | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null)
    [[ -n "$alpn_json" && "$alpn_json" != "[]" ]] || alpn_json='["h3"]'

    if ! output=$(jq -nc \
        --arg server "$server" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg password "$password" \
        --arg cc "$cc" \
        --arg ur "$ur" \
        --arg sni "$sni" \
        --argjson insecure "$insecure" \
        --argjson alpn "$alpn_json" \
        '{type:"tuic",tag:"proxy",server:$server,server_port:$port,uuid:$uuid,password:$password,
          congestion_control:$cc,udp_relay_mode:$ur,
          tls:{enabled:true,server_name:$sni,insecure:$insecure,alpn:$alpn}}'); then
        _fatal "生成 TUIC outbound 失败"
    fi
    printf '%s\n' "$output"
}

# SX: Trojan 链接解析 (tcp / ws)
_parse_trojan_uri() {
    local link body authority query password endpoint server port
    local security sni insecure trans path host output
    link="$1"
    [[ "$link" == trojan://* ]] || _fatal "链接必须以 trojan:// 开头"
    body="${link#trojan://}"
    body="${body%%#*}"
    [[ -n "$body" ]] || _fatal "Trojan 链接为空"

    if [[ "$body" == *\?* ]]; then
        authority="${body%%\?*}"
        query="${body#*\?}"
    else
        authority="$body"
        query=""
    fi

    [[ "$authority" == *@* ]] || _fatal "Trojan 链接缺少密码或服务器地址"
    password="${authority%%@*}"
    endpoint="${authority#*@}"
    [[ "$endpoint" != *@* ]] || _fatal "Trojan 链接的服务器地址格式错误"
    _url_decode "$password" 0 || _fatal "Trojan 密码包含无效 URL 编码"
    password="$DECODED_VALUE"
    [[ -n "$password" && "$password" != *[[:space:]]* ]] || _fatal "Trojan 密码格式无效"

    _split_host_port "$endpoint" || _fatal "Trojan 服务器地址或端口无效"
    server="$PARSED_SERVER"
    port="$PARSED_PORT"
    _parse_query "$query" || _fatal "Trojan 查询参数格式无效或包含重复参数"
    _require_query_keys security sni allowInsecure allow_insecure type path host fp alpn

    security="${QUERY_PARAMS[security]-tls}"
    sni="${QUERY_PARAMS[sni]-}"
    insecure="${QUERY_PARAMS[allowInsecure]-${QUERY_PARAMS[allow_insecure]-}}"
    trans="${QUERY_PARAMS[type]-tcp}"
    path="${QUERY_PARAMS[path]-}"
    host="${QUERY_PARAMS[host]-}"

    case "$insecure" in
        ""|0) insecure="false" ;;
        1) insecure="true" ;;
        *) _fatal "Trojan allowInsecure 参数仅允许 0 或 1" ;;
    esac
    case "$trans" in
        tcp|"") trans="tcp" ;;
        ws) ;;
        *) _fatal "Trojan 仅支持 tcp 或 ws 传输" ;;
    esac

    local tls_part="{}"
    if [[ "$security" == "tls" || "$security" == "none" && "$trans" == "ws" ]]; then
        [[ -n "$sni" ]] || sni="$server"
        _validate_server "$sni" || _fatal "Trojan SNI 无效"
        tls_part=$(jq -nc --arg sni "$sni" --argjson insecure "$insecure" '{enabled:true,server_name:$sni,insecure:$insecure}')
    elif [[ "$security" == "none" ]]; then
        tls_part="{}"
    else
        _fatal "Trojan security 仅支持 tls 或 none"
    fi

    local transport_part="{}"
    if [[ "$trans" == "ws" ]]; then
        [[ -n "$path" && "$path" == /* ]] || _fatal "Trojan WS 节点缺少以 / 开头的 path"
        # SX: 剥离 path 内 query (?ed=2560) 并映射为 early data
        local tj_query="" tj_early="{}"
        if [[ "$path" == *\?* ]]; then
            tj_query="${path#*\?}"
            path="${path%%\?*}"
            if [[ "$tj_query" =~ (^|&)ed=([0-9]+) ]]; then
                tj_early=$(jq -nc --argjson ed "${BASH_REMATCH[2]}" '{max_early_data:$ed,early_data_header_name:"Sec-WebSocket-Protocol"}')
            fi
        fi
        [[ -n "$path" && "$path" == /* ]] || _fatal "Trojan WS 节点缺少以 / 开头的 path"
        [[ -n "$host" ]] || host="$sni"
        _validate_server "$host" || _fatal "Trojan WS Host 无效"
        transport_part=$(jq -nc --arg p "$path" --arg h "$host" --argjson early "$tj_early" '({type:"ws",path:$p,headers:{Host:$h}} + $early)')
    fi

    if ! output=$(jq -nc \
        --arg server "$server" \
        --argjson port "$port" \
        --arg password "$password" \
        --argjson tls "$tls_part" \
        --argjson transport "$transport_part" \
        '{type:"trojan",tag:"proxy",server:$server,server_port:$port,password:$password}
            + (if $tls != {} then {tls:$tls} else {} end)
            + (if $transport != {} then {transport:$transport} else {} end)'); then
        _fatal "生成 Trojan outbound 失败"
    fi
    printf '%s\n' "$output"
}

# SX: auto 模式 —— 按链接 scheme 自动识别并分发到对应解析器
# _fatal 在 _emit_auto 参数的命令替换里 exit 1 会被吞, 使 auto 拿着 {"error":...} 且 rc=0 返回
# (调用方误当成功去跑 schema 校验)。此处复查 error 对象, 重新以非零码退出保持契约一致。
_emit_auto() {
    local mode="$1" json="$2"
    if ! printf '%s' "$json" | jq -e '.error == null' >/dev/null 2>&1; then
        printf '%s\n' "$json"
        exit 1
    fi
    jq -c --arg m "$mode" '. + {_detected_mode:$m}' <<<"$json"
}

_parse_auto() {
    local link="$1" scheme userinfo decoded method
    [[ "$link" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*):// ]] || _fatal "无法识别的链接格式 (缺少 xxx:// 协议前缀)"
    scheme="${BASH_REMATCH[1],,}"
    # 协议头大小写归一 (实测: HYSTERIA2:// 直接被各解析器拒收)
    link="${link/${BASH_REMATCH[0]}/${scheme}://}"

    case "$scheme" in
        vless)
            if printf '%s' "$link" | grep -qE '[?&]security=reality'; then
                _emit_auto "vless-reality-vision" "$(_parse_vless_reality_vision "$link")"
            elif printf '%s' "$link" | grep -qE '[?&]type=ws'; then
                _emit_auto "vless-ws-tls" "$(_parse_vless_ws_tls "$link")"
            else
                _emit_auto "vless-tcp" "$(_parse_vless_tcp "$link")"
            fi
            ;;
        hysteria2|hy2)
            _emit_auto "hysteria2" "$(_parse_hysteria2_uri "$link")"
            ;;
        tuic)
            _emit_auto "tuic" "$(_parse_tuic_uri "$link")"
            ;;
        trojan)
            _emit_auto "trojan" "$(_parse_trojan_uri "$link")"
            ;;
        ss)
            userinfo="${link#ss://}"
            userinfo="${userinfo%%#*}"
            userinfo="${userinfo%%\?*}"
            userinfo="${userinfo%%@*}"
            method=""
            if [[ "$userinfo" == *:* ]]; then
                method="${userinfo%%:*}"
            elif [ -n "$userinfo" ]; then
                local pad=$(( (4 - ${#userinfo} % 4) % 4 ))
                local padded="$userinfo"
                [ "$pad" -eq 2 ] && padded="${padded}=="
                [ "$pad" -eq 3 ] && padded="${padded}="
                decoded=$(printf '%s' "$padded" | tr '_-' '/+' | base64 -d 2>/dev/null) || decoded=""
                method="${decoded%%:*}"
            fi
            case "$method" in
                aes-128-gcm)      _emit_auto "ss-aes-128-gcm"      "$(_parse_ss_uri "$link" "aes-128-gcm")" ;;
                aes-256-gcm)      _emit_auto "ss-aes-256-gcm"      "$(_parse_ss_uri "$link" "aes-256-gcm")" ;;
                2022-blake3-aes-128-gcm) _emit_auto "ss-2022-aes-128-gcm" "$(_parse_ss_uri "$link" "2022-blake3-aes-128-gcm")" ;;
                2022-blake3-aes-256-gcm) _emit_auto "ss-2022-aes-256-gcm" "$(_parse_ss_uri "$link" "2022-blake3-aes-256-gcm")" ;;
                *) _fatal "SS 加密方式 [$method] 不在自动识别列表 (aes-128/256-gcm, 2022-blake3), 请手动选择 [4][5][10][11]" ;;
            esac
            ;;
        https|http)
            _emit_auto "https-proxy" "$(_parse_http_uri "$link")"
            ;;
        socks5|socks)
            _fatal "SOCKS5 链接导入请使用手动输入 [8][9]"
            ;;
        *)
            _fatal "暂不支持自动识别协议: $scheme:// (支持 vless/hysteria2/tuic/trojan/ss/http)"
            ;;
    esac
}

_read_link() {
    local argument_count extra read_status
    argument_count="$1"
    if (( argument_count == 2 )); then
        LINK_INPUT="$2"
    else
        LINK_INPUT=""
        if ! IFS= read -r LINK_INPUT; then
            [[ -n "$LINK_INPUT" ]] || _fatal "未从标准输入读取到节点链接"
        fi

        while true; do
            extra=""
            IFS= read -r extra
            read_status=$?
            extra="${extra%$'\r'}"
            [[ -z "$extra" ]] || _fatal "标准输入只能包含一条节点链接"
            (( read_status == 0 )) || break
        done
    fi

    LINK_INPUT="${LINK_INPUT%$'\r'}"
    # 去首尾空白 (实测: 末尾空格会让非 vless 分支认不出协议前缀)
    LINK_INPUT="${LINK_INPUT#"${LINK_INPUT%%[![:space:]]*}"}"
    LINK_INPUT="${LINK_INPUT%"${LINK_INPUT##*[![:space:]]}"}"
    [[ -n "$LINK_INPUT" ]] || _fatal "节点链接不能为空"
    [[ "$LINK_INPUT" != *$'\r'* && "$LINK_INPUT" != *$'\n'* ]] || _fatal "节点链接不能包含换行符"
}

(( $# == 1 || $# == 2 )) || _fatal "用法：bash parser.sh MODE（节点链接从标准输入传入）"

MODE="$1"
case "$MODE" in
    vless-reality-vision|vless-tcp|vless-ws-tls|ss-aes-128-gcm|ss-aes-256-gcm|ss-2022-aes-128-gcm|ss-2022-aes-256-gcm|https-proxy|hysteria2|tuic|trojan|auto) ;;
    *) _fatal "不支持的解析模式" ;;
esac

command -v jq >/dev/null 2>&1 || _fatal "缺少 jq 依赖"
case "$MODE" in
    ss-aes-128-gcm|ss-aes-256-gcm|ss-2022-aes-128-gcm|ss-2022-aes-256-gcm)
        command -v base64 >/dev/null 2>&1 || _fatal "缺少 base64 依赖"
        ;;
esac

_read_link "$#" "${2-}"

case "$MODE" in
    vless-reality-vision) _parse_vless_reality_vision "$LINK_INPUT" ;;
    vless-tcp) _parse_vless_tcp "$LINK_INPUT" ;;
    vless-ws-tls) _parse_vless_ws_tls "$LINK_INPUT" ;;
    ss-aes-128-gcm) _parse_ss_uri "$LINK_INPUT" "aes-128-gcm" ;;
    ss-aes-256-gcm) _parse_ss_uri "$LINK_INPUT" "aes-256-gcm" ;;
    ss-2022-aes-128-gcm) _parse_ss_uri "$LINK_INPUT" "2022-blake3-aes-128-gcm" ;;
    ss-2022-aes-256-gcm) _parse_ss_uri "$LINK_INPUT" "2022-blake3-aes-256-gcm" ;;
    https-proxy) _parse_http_uri "$LINK_INPUT" ;;
    hysteria2) _parse_hysteria2_uri "$LINK_INPUT" ;;
    tuic) _parse_tuic_uri "$LINK_INPUT" ;;
    trojan) _parse_trojan_uri "$LINK_INPUT" ;;
    auto) _parse_auto "$LINK_INPUT" ;;
esac
