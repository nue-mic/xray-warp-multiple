#!/bin/bash
# =============================================================================
# ArgoSB-WARP-Argo
#   VPS / Linux: N 个本地 vmess-ws 入站 -> N 套独立 WARP 出口 ->
#   N 个 Cloudflare 临时隧道 (*.trycloudflare.com) 分别暴露。
#
# 用法：
#   num=5 bash argosb-nw-warp-argo.sh
#   num=3 startport=20000 bash argosb-nw-warp-argo.sh
#   ports="20001 20002 30000" bash argosb-nw-warp-argo.sh
#   uuid="123e4567-e89b-12d3-a456-426614174000" num=4 bash argosb-nw-warp-argo.sh
#   uniq=y num=5 bash argosb-nw-warp-argo.sh
#   prefer_suffixes="fast.rthink.vip cf.rthink.vip" num=5 startport=20000 bash argosb-nw-warp-argo.sh
#
# 管理：
#   bash argosb-nw-warp-argo.sh list
#   bash argosb-nw-warp-argo.sh del
#
# 说明：
#   1. 每个端口会注册一套免费 WARP 账号，xray 用 inboundTag -> warp-N 分流。
#   2. 每个本地端口启动一个 cloudflared 临时隧道，生成独立 trycloudflare 域名。
#   3. 默认把节点 add/server 改写为“随机前缀.优选后缀”；Host/SNI 仍保持 trycloudflare 真域名。
#   4. 临时隧道域名在服务重启后会变化，list 看到的是最近一次启动生成的链接。
#   5. 免费 WARP 不保证每个出口公网 IP 都不同；需要时使用 uniq=y 强制探测去重。
# =============================================================================
set -o pipefail
export LANG=en_US.UTF-8

WORKDIR="$HOME/agsb-wa"
BIN="$WORKDIR/xray"
CLOUDFLARED="$WORKDIR/cloudflared"
CONF="$WORKDIR/xr.json"
INFO="$WORKDIR/nodes.txt"
META="$WORKDIR/meta.env"
TUNNELS="$WORKDIR/tunnels.tsv"
RUNNER="$WORKDIR/run.sh"
SUBDIR="$WORKDIR/sub"

red(){ echo -e "\033[31m$1\033[0m"; }
green(){ echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }

cmd="$1"

uninstall_self(){
  local removed=0
  green "开始卸载 ArgoSB-WARP-Argo（仅清理自身）..."

  if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/agsb-wa.service ]; then
    systemctl stop agsb-wa 2>/dev/null
    systemctl disable agsb-wa 2>/dev/null
    rm -f /etc/systemd/system/agsb-wa.service
    systemctl daemon-reload 2>/dev/null
    yellow "  ✓ 已移除 systemd 服务 agsb-wa"
    removed=1
  fi

  if command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/agsb-wa ]; then
    rc-service agsb-wa stop 2>/dev/null
    rc-update del agsb-wa default 2>/dev/null
    rm -f /etc/init.d/agsb-wa
    yellow "  ✓ 已移除 OpenRC 服务 agsb-wa"
    removed=1
  fi

  local pids
  pids=$(pgrep -f "$WORKDIR/xray" 2>/dev/null)
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null
    sleep 1
    pids=$(pgrep -f "$WORKDIR/xray" 2>/dev/null)
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    yellow "  ✓ 已结束自身 xray 进程"
    removed=1
  fi

  pkill -f "$WORKDIR/cloudflared tunnel" 2>/dev/null && {
    yellow "  ✓ 已结束自身 cloudflared 临时隧道进程"
    removed=1
  }

  pids=$(pgrep -f "$WORKDIR/run.sh" 2>/dev/null)
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null
    sleep 1
    pids=$(pgrep -f "$WORKDIR/run.sh" 2>/dev/null)
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    yellow "  ✓ 已结束自身 supervisor 进程"
    removed=1
  fi

  if [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
    yellow "  ✓ 已删除工作目录 $WORKDIR"
    removed=1
  fi

  echo
  [ "$removed" = 1 ] && green "卸载完成。" || yellow "未发现安装痕迹。"
  echo "未改动：~/agsb-mw、~/agsb-ww、~/agsbx、其它 xray/cloudflared、bashrc、crontab。"
}

if [ "$cmd" = "del" ] || [ "$cmd" = "uninstall" ]; then
  uninstall_self
  exit 0
fi

if [ "$cmd" = "list" ]; then
  if [ -f "$INFO" ]; then
    cat "$INFO"
  else
    red "未安装或临时隧道尚未生成。"
    [ -d "$WORKDIR/logs" ] && echo "可查看日志：$WORKDIR/logs/"
  fi
  exit 0
fi

detect_pm(){
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v apk >/dev/null 2>&1; then echo apk
  elif command -v pacman >/dev/null 2>&1; then echo pacman
  elif command -v zypper >/dev/null 2>&1; then echo zypper
  else echo none; fi
}

pm_install(){
  local pm=$1
  shift
  case "$pm" in
    apt)    apt-get install -y --no-install-recommends "$@" >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1; apt-get install -y --no-install-recommends "$@" >/dev/null 2>&1; } ;;
    dnf)    dnf install -y "$@" >/dev/null 2>&1 ;;
    yum)    yum install -y "$@" >/dev/null 2>&1 ;;
    apk)    apk add --no-cache "$@" >/dev/null 2>&1 ;;
    pacman) pacman -Sy --noconfirm "$@" >/dev/null 2>&1 ;;
    zypper) zypper --non-interactive install "$@" >/dev/null 2>&1 ;;
  esac
}

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"
PM=$(detect_pm)

ensure_pkg(){
  local c="$1" pkg="${2:-$1}"
  command -v "$c" >/dev/null 2>&1 && return 0
  [ "$PM" = none ] && { red "缺少依赖：$c，请手动安装后重试。"; return 1; }
  yellow "缺少依赖 $c，正在自动安装..."
  if [ -n "$SUDO" ]; then
    $SUDO bash -c "$(declare -f pm_install); pm_install $PM $pkg"
  else
    pm_install "$PM" "$pkg"
  fi
  command -v "$c" >/dev/null 2>&1 && return 0
  red "自动安装 $c 失败，请手动安装：$pkg"
  return 1
}

b64_one_line(){
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

random_label(){
  local hex
  hex=$(od -An -N4 -tx4 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -z "$hex" ] && hex="$(date +%s)$RANDOM"
  echo "wa-$hex"
}

pick_prefer_suffix(){
  local idx="$1" suffix_arr count pos
  suffix_arr=($prefer_suffixes)
  count=${#suffix_arr[@]}
  [ "$count" -gt 0 ] || return 1
  pos=$(( (idx - 1) % count ))
  echo "${suffix_arr[$pos]}"
}

for c in curl openssl python3; do ensure_pkg "$c" || exit 1; done
mkdir -p "$WORKDIR/logs" "$SUBDIR"

uuid="${uuid:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null)}"
[ -z "$uuid" ] && uuid="$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
if ! echo "$uuid" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
  red "uuid 格式不合法，应为 8-4-4-4-12 十六进制格式。"
  exit 1
fi

wspath="${wspath:-/argosbwa}"
uniq="${uniq:-n}"
maxtry="${maxtry:-30}"
regretry="${regretry:-12}"
regsleep="${regsleep:-3}"
tunnel_wait="${tunnel_wait:-60}"
sub_port="${sub_port:-$(( (RANDOM % 10000) + 40000 ))}"
prefer="${prefer:-y}"
DEFAULT_PREFER_SUFFIXES="fast.rthink.vip cf.rthink.vip turbo.rthink.vip edge.rthink.vip flare.rthink.vip saas.rthink.vip"
prefer_suffixes="${prefer_suffixes:-$DEFAULT_PREFER_SUFFIXES}"

if [ -n "$ports" ]; then
  PORT_LIST=($ports)
else
  num="${num:-3}"
  startport="${startport:-$(( (RANDOM % 20000) + 20000 ))}"
  PORT_LIST=()
  for i in $(seq 0 $((num-1))); do PORT_LIST+=( $((startport+i)) ); done
fi
N=${#PORT_LIST[@]}
[ "$N" -gt 0 ] || { red "端口数量为空。"; exit 1; }

for p in "${PORT_LIST[@]}"; do
  if ! echo "$p" | grep -Eq '^[0-9]+$' || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
    red "端口不合法：$p"
    exit 1
  fi
done

green "将创建 $N 个本地 vmess-ws 入站，并为每个入站申请一个 Cloudflare 临时隧道。"
yellow "注意：临时隧道域名会在服务重启后变化，请用 list 查看最新链接。"
if [ "$N" -gt 20 ]; then
  yellow "端口数较多：将注册 $N 套 WARP 并启动 $N 个 cloudflared，可能触发限流或占用较多内存。"
fi

serverip=$(curl -s4m8 https://api.ipify.org 2>/dev/null || curl -s6m8 https://api64.ipify.org 2>/dev/null)
if echo "$serverip" | grep -q ':'; then v6only=1; else v6only=0; fi
if [ "$v6only" = 1 ]; then
  ENDPOINT_POOL="[2606:4700:d0::a29f:c001]:2408 [2606:4700:d0::a29f:c005]:2408 [2606:4700:d0::a29f:c010]:2408 [2606:4700:d0::a29f:c019]:2408 [2606:4700:d0::a29f:c025]:2408"
else
  ENDPOINT_POOL="162.159.192.1:2408 162.159.193.10:2408 188.114.98.1:2408 188.114.99.1:2408 162.159.192.5:2408 162.159.193.5:2408 188.114.98.224:2408 162.159.192.9:2408"
fi
EP_ARR=($ENDPOINT_POOL)
EP_N=${#EP_ARR[@]}
WARP_ENDPOINT="${EP_ARR[0]}"

download_xray(){
  [ -x "$BIN" ] && return 0
  green "下载 xray 内核..."
  local xarch ver
  case "$(uname -m)" in
    x86_64|amd64) xarch="64" ;;
    aarch64|arm64) xarch="arm64-v8a" ;;
    armv7l) xarch="arm32-v7a" ;;
    s390x) xarch="s390x" ;;
    *) red "不支持的 xray 架构：$(uname -m)"; return 1 ;;
  esac
  ver=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep -oE '"tag_name":[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"(v[^"]*)"$/\1/')
  [ -z "$ver" ] && ver="v25.6.8"
  curl -Lso "$WORKDIR/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${xarch}.zip" || return 1
  if command -v unzip >/dev/null 2>&1; then
    (cd "$WORKDIR" && unzip -oq xray.zip xray)
  elif command -v python3 >/dev/null 2>&1; then
    (cd "$WORKDIR" && python3 -c "import zipfile; zipfile.ZipFile('xray.zip').extract('xray')")
  else
    ensure_pkg unzip && (cd "$WORKDIR" && unzip -oq xray.zip xray)
  fi
  chmod +x "$BIN" 2>/dev/null
  rm -f "$WORKDIR/xray.zip"
  [ -x "$BIN" ] || { red "xray 下载失败。"; return 1; }
}

download_cloudflared(){
  [ -x "$CLOUDFLARED" ] && return 0
  green "下载 cloudflared 内核..."
  local carch
  case "$(uname -m)" in
    x86_64|amd64) carch="amd64" ;;
    aarch64|arm64) carch="arm64" ;;
    armv7l|armv6l) carch="arm" ;;
    i386|i686) carch="386" ;;
    *) red "不支持的 cloudflared 架构：$(uname -m)"; return 1 ;;
  esac
  curl -Lso "$CLOUDFLARED" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${carch}" || return 1
  chmod +x "$CLOUDFLARED" 2>/dev/null
  [ -x "$CLOUDFLARED" ] || { red "cloudflared 下载失败。"; return 1; }
}

download_xray || exit 1
download_cloudflared || exit 1

warp_register(){
  local kd priv pub body code cid v6 tries=0 wait=5
  body=$(mktemp)
  while [ $tries -lt "$regretry" ]; do
    tries=$((tries+1))
    kd=$(mktemp -d)
    openssl genpkey -algorithm X25519 -out "$kd/p.pem" 2>/dev/null
    priv=$(openssl pkey -in "$kd/p.pem" -outform DER 2>/dev/null | tail -c 32 | b64_one_line)
    pub=$(openssl pkey -in "$kd/p.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | b64_one_line)
    rm -rf "$kd"

    code=$(curl -s -o "$body" -w '%{http_code}' --max-time 15 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
      -H "User-Agent: okhttp/3.12.1" \
      -H "CF-Client-Version: a-6.30-3596" \
      -H "Content-Type: application/json" \
      -d "{\"key\":\"${pub}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"PC\",\"serial_number\":\"\",\"locale\":\"en_US\"}")

    if [ "$code" = 200 ]; then
      cid=$(grep -o '"client_id":"[^"]*"' "$body" | head -1 | cut -d'"' -f4)
      v6=$(grep -o '"v6":"[0-9a-fA-F:]\{2,\}"' "$body" | head -1 | cut -d'"' -f4)
      if [ -n "$cid" ] && [ -n "$v6" ]; then
        PRIV="$priv"
        RESERVED=$(echo "$cid" | base64 -d 2>/dev/null | od -An -tu1 | tr -s ' ' | sed 's/^ //;s/ $//;s/ /,/g')
        V6ADDR="$v6"
        rm -f "$body"
        return 0
      fi
    fi

    if [ "$code" = 429 ]; then
      yellow "      CF 限流(429/1015)，退避 ${wait}s 后重试（第 $tries 次）..."
    else
      yellow "      注册无响应(HTTP=${code:-超时})，${wait}s 后重试（第 $tries 次）..."
    fi
    sleep "$wait"
    wait=$((wait+5))
    [ $wait -gt 45 ] && wait=45
  done
  rm -f "$body"
  return 1
}

warp_probe_ip(){
  local priv="$1" v6="$2" res="$3" ep="$4" sp cfg pid ip t
  sp=$(( (RANDOM % 10000) + 30000 ))
  cfg=$(mktemp)
  cat > "$cfg" <<EOF
{ "log": { "loglevel": "error" },
  "inbounds": [ { "tag": "in", "listen": "127.0.0.1", "port": $sp, "protocol": "socks", "settings": { "udp": true } } ],
  "outbounds": [ { "tag": "w", "protocol": "wireguard", "settings": {
      "secretKey": "$priv", "address": [ "172.16.0.2/32", "$v6/128" ],
      "peers": [ { "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "allowedIPs": [ "0.0.0.0/0", "::/0" ], "endpoint": "$ep" } ],
      "reserved": [$res] } } ] }
EOF
  "$BIN" run -c "$cfg" >/dev/null 2>&1 &
  pid=$!
  sleep 3
  for t in 1 2 3; do
    ip=$(curl -s --max-time 10 --socks5-hostname "127.0.0.1:$sp" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p')
    [ -n "$ip" ] && break
    sleep 2
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rm -f "$cfg"
  echo "$ip"
}

acquire_unique(){
  local t=0 ep egress
  while [ $t -lt "$maxtry" ]; do
    t=$((t+1))
    if ! warp_register; then
      yellow "    第 $t 次：账号注册失败，重试..."
      sleep 2
      continue
    fi
    ep="${EP_ARR[$(( (t-1) % EP_N ))]}"
    egress=$(warp_probe_ip "$PRIV" "$V6ADDR" "$RESERVED" "$ep")
    if [ -z "$egress" ]; then
      yellow "    第 $t 次：出口探测失败，重试..."
      continue
    fi
    if echo " $USED_IPS " | grep -q " $egress "; then
      yellow "    第 $t 次：出口 IP $egress 与已有重复，重新注册..."
      continue
    fi
    ENDPT="$ep"
    EGRESS="$egress"
    USED_IPS="$USED_IPS $egress"
    green "    ✓ 取得唯一出口 IP：$egress"
    return 0
  done
  return 1
}

INBOUNDS=""
OUTBOUNDS=""
RULES=""
USED_IPS=""
: > "$TUNNELS"
: > "$META"
echo "uuid=$uuid" >> "$META"
echo "wspath=$wspath" >> "$META"
printf 'ports="%s"\n' "${PORT_LIST[*]}" >> "$META"
echo "tunnel_wait=$tunnel_wait" >> "$META"
echo "sub_port=$sub_port" >> "$META"
printf 'prefer="%s"\n' "$prefer" >> "$META"
printf 'prefer_suffixes="%s"\n' "$prefer_suffixes" >> "$META"

idx=0
for p in "${PORT_LIST[@]}"; do
  idx=$((idx+1))
  yellow "  [$idx/$N] 本地端口 $p 获取独立 WARP 出口..."
  if [ "$uniq" = y ]; then
    if ! acquire_unique; then
      red "端口 $p 在 $maxtry 次尝试内无法取得唯一出口 IP，已中止。"
      exit 1
    fi
  else
    if ! warp_register; then
      red "端口 $p 的 WARP 注册失败，已中止。"
      exit 1
    fi
    ENDPT="${EP_ARR[$(( (idx-1) % EP_N ))]}"
    EGRESS="未校验"
  fi

  INBOUNDS+='
    {
      "tag": "vmess-'"$idx"'",
      "listen": "127.0.0.1",
      "port": '"$p"',
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "'"$uuid"'" } ] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "'"$wspath"'" }
      }
    },'

  OUTBOUNDS+='
    {
      "tag": "warp-'"$idx"'",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "'"$PRIV"'",
        "address": [ "172.16.0.2/32", "'"$V6ADDR"'/128" ],
        "peers": [ {
          "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowedIPs": [ "0.0.0.0/0", "::/0" ],
          "endpoint": "'"$ENDPT"'"
        } ],
        "reserved": ['"$RESERVED"']
      }
    },'

  RULES+='
      { "type": "field", "inboundTag": ["vmess-'"$idx"'"], "outboundTag": "warp-'"$idx"'" },'

  printf '%s\t%s\t%s\n' "$idx" "$p" "$EGRESS" >> "$TUNNELS"
  [ $idx -lt $N ] && sleep "$regsleep"
done

INBOUNDS="${INBOUNDS%,}"
OUTBOUNDS="${OUTBOUNDS%,}"
RULES="${RULES%,}"

if [ "$uniq" = y ]; then
  total=$(echo $USED_IPS | wc -w)
  distinct=$(echo $USED_IPS | tr ' ' '\n' | sort -u | grep -c .)
  if [ "$total" -ne "$N" ] || [ "$distinct" -ne "$N" ]; then
    red "最终唯一性校验失败：期望 $N 个不同出口，实际 total=$total distinct=$distinct。"
    exit 1
  fi
fi

cat > "$CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ $INBOUNDS
  ],
  "outbounds": [ $OUTBOUNDS,
    { "protocol": "freedom", "tag": "direct" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [ $RULES
    ]
  }
}
EOF

if ! "$BIN" run -test -c "$CONF" >/dev/null 2>"$WORKDIR/test.err"; then
  red "xray 配置自检失败："
  cat "$WORKDIR/test.err"
  exit 1
fi
green "xray 配置自检通过。"

cat > "$RUNNER" <<'EOF'
#!/bin/bash
set -o pipefail

WORKDIR="$HOME/agsb-wa"
BIN="$WORKDIR/xray"
CLOUDFLARED="$WORKDIR/cloudflared"
CONF="$WORKDIR/xr.json"
INFO="$WORKDIR/nodes.txt"
TUNNELS="$WORKDIR/tunnels.tsv"
META="$WORKDIR/meta.env"
LOGDIR="$WORKDIR/logs"
SUBDIR="$WORKDIR/sub"
V2RAY_SUB="$SUBDIR/v2ray"
CLASH_SUB="$SUBDIR/clash.yaml"

. "$META"
mkdir -p "$LOGDIR" "$SUBDIR"

b64_one_line(){
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

random_label(){
  local hex
  hex=$(od -An -N4 -tx4 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -z "$hex" ] && hex="$(date +%s)$RANDOM"
  echo "wa-$hex"
}

pick_prefer_suffix(){
  local idx="$1" suffix_arr count pos
  suffix_arr=($prefer_suffixes)
  count=${#suffix_arr[@]}
  [ "$count" -gt 0 ] || return 1
  pos=$(( (idx - 1) % count ))
  echo "${suffix_arr[$pos]}"
}

cleanup(){
  [ -n "$XRAY_PID" ] && kill "$XRAY_PID" 2>/dev/null
  [ -n "$SUB_PID" ] && kill "$SUB_PID" 2>/dev/null
  if [ -n "$CF_PIDS" ]; then
    kill $CF_PIDS 2>/dev/null
  fi
  wait 2>/dev/null
}
trap cleanup INT TERM EXIT

rm -f "$LOGDIR"/argo-*.log "$INFO.tmp"
rm -f "$LOGDIR"/sub-argo.log "$LOGDIR"/sub-http.log "$SUBDIR"/vmess.links.tmp "$SUBDIR"/node.names.tmp "$CLASH_SUB.tmp" "$V2RAY_SUB.tmp"
"$BIN" run -c "$CONF" > "$LOGDIR/xray.log" 2>&1 &
XRAY_PID=$!
sleep 2

if ! kill -0 "$XRAY_PID" 2>/dev/null; then
  echo "xray 启动失败，请查看 $LOGDIR/xray.log" > "$INFO"
  exit 1
fi

wait_domain(){
  local log="$1" waited=0 domain=""
  while [ "$waited" -lt "${tunnel_wait:-60}" ]; do
    domain=$(grep -aoE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "$log" 2>/dev/null | head -1 | sed 's#https://##')
    [ -n "$domain" ] && { echo "$domain"; return 0; }
    sleep 1
    waited=$((waited+1))
  done
  return 1
}

{
  echo "ArgoSB-WARP-Argo 节点信息"
  echo "生成时间：$(date '+%F %T %Z')"
  echo "说明：trycloudflare 临时域名重启后会变化，请以本文件最新内容为准。"
  echo
} > "$INFO.tmp"

: > "$SUBDIR/vmess.links.tmp"
{
  echo "proxies:"
} > "$CLASH_SUB.tmp"

CF_PIDS=""
while IFS="$(printf '\t')" read -r idx port egress; do
  [ -n "$idx" ] || continue
  log="$LOGDIR/argo-$idx.log"
  "$CLOUDFLARED" tunnel --url http://127.0.0.1:"$port" --edge-ip-version auto --no-autoupdate --protocol http2 > "$log" 2>&1 &
  cpid=$!
  CF_PIDS="$CF_PIDS $cpid"
  domain=$(wait_domain "$log")

  if [ -z "$domain" ]; then
    {
      echo "[$idx] 本地端口 $port -> 临时隧道申请失败"
      echo "    日志：$log"
      echo
    } >> "$INFO.tmp"
    continue
  fi

  server_domain="$domain"
  if [ "${prefer:-y}" = y ]; then
    suffix=$(pick_prefer_suffix "$idx")
    [ -n "$suffix" ] && server_domain="$(random_label).$suffix"
  fi

  vmess_json=$(printf '{"v":"2","ps":"WA-warp-%s-%s","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s","alpn":""}' "$idx" "$port" "$server_domain" "$uuid" "$domain" "$wspath" "$domain")
  vmess_link="vmess://$(printf '%s' "$vmess_json" | b64_one_line)"
  node_name="WA-warp-$idx-$port"
  printf '%s\n' "$vmess_link" >> "$SUBDIR/vmess.links.tmp"
  printf '%s\n' "$node_name" >> "$SUBDIR/node.names.tmp"
  {
    echo "  - name: \"$node_name\""
    echo "    type: vmess"
    echo "    server: $server_domain"
    echo "    port: 443"
    echo "    uuid: $uuid"
    echo "    alterId: 0"
    echo "    cipher: auto"
    echo "    udp: true"
    echo "    tls: true"
    echo "    network: ws"
    echo "    ws-opts:"
    echo "      path: $wspath"
    echo "      headers:"
    echo "        Host: $domain"
    echo "    servername: $domain"
    echo "    skip-cert-verify: true"
  } >> "$CLASH_SUB.tmp"
  {
    echo "[$idx] $server_domain:443  Host/SNI=$domain  ->  127.0.0.1:$port  ->  WARP 出口 #$idx  出口IP=$egress"
    echo "$vmess_link"
    echo
  } >> "$INFO.tmp"
done < "$TUNNELS"

if [ -s "$SUBDIR/vmess.links.tmp" ]; then
  b64_one_line < "$SUBDIR/vmess.links.tmp" > "$V2RAY_SUB.tmp"
  {
    echo
    echo "proxy-groups:"
    echo "  - name: WA-AUTO"
    echo "    type: select"
    echo "    proxies:"
    while IFS= read -r node_name; do
      [ -n "$node_name" ] && echo "      - $node_name"
    done < "$SUBDIR/node.names.tmp"
    echo
    echo "rules:"
    echo "  - MATCH,WA-AUTO"
  } >> "$CLASH_SUB.tmp"
  mv "$V2RAY_SUB.tmp" "$V2RAY_SUB"
  mv "$CLASH_SUB.tmp" "$CLASH_SUB"
fi

python3 -m http.server "${sub_port:-48080}" --bind 127.0.0.1 --directory "$SUBDIR" > "$LOGDIR/sub-http.log" 2>&1 &
SUB_PID=$!
sleep 1
if kill -0 "$SUB_PID" 2>/dev/null; then
  "$CLOUDFLARED" tunnel --url http://127.0.0.1:"${sub_port:-48080}" --edge-ip-version auto --no-autoupdate --protocol http2 > "$LOGDIR/sub-argo.log" 2>&1 &
  sub_cpid=$!
  CF_PIDS="$CF_PIDS $sub_cpid"
  sub_domain=$(wait_domain "$LOGDIR/sub-argo.log")
  if [ -n "$sub_domain" ]; then
    sub_server_domain="$sub_domain"
    if [ "${prefer:-y}" = y ]; then
      sub_suffix=$(pick_prefer_suffix 1)
      [ -n "$sub_suffix" ] && sub_server_domain="$(random_label).$sub_suffix"
    fi
    {
      echo "订阅链接"
      echo "V2Ray真实订阅：https://$sub_domain/v2ray"
      echo "Clash真实订阅：https://$sub_domain/clash.yaml"
      echo "V2Ray优选订阅：https://$sub_server_domain/v2ray"
      echo "Clash优选订阅：https://$sub_server_domain/clash.yaml"
      echo "说明：普通订阅 URL 不能像 VMess 节点一样单独指定 Host/SNI；优选订阅是否可直连取决于你的优选域名解析/CDN规则。"
      echo
    } >> "$INFO.tmp"
  else
    {
      echo "订阅链接申请失败"
      echo "日志：$LOGDIR/sub-argo.log"
      echo
    } >> "$INFO.tmp"
  fi
else
  {
    echo "订阅 HTTP 服务启动失败"
    echo "日志：$LOGDIR/sub-http.log"
    echo
  } >> "$INFO.tmp"
fi

mv "$INFO.tmp" "$INFO"
while true; do
  if ! kill -0 "$XRAY_PID" 2>/dev/null; then
    echo "xray 已退出，supervisor 将重启服务。" >> "$LOGDIR/supervisor.log"
    exit 1
  fi
  if ! kill -0 "$SUB_PID" 2>/dev/null; then
    echo "订阅 HTTP 服务已退出，supervisor 将重启服务。" >> "$LOGDIR/supervisor.log"
    exit 1
  fi
  for pid in $CF_PIDS; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "cloudflared PID $pid 已退出，supervisor 将重启服务。" >> "$LOGDIR/supervisor.log"
      exit 1
    fi
  done
  sleep 10
done
EOF
chmod +x "$RUNNER"

if pidof systemd >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  cat > /etc/systemd/system/agsb-wa.service <<EOF
[Unit]
Description=ArgoSB WARP Argo temporary tunnels
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$RUNNER
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable agsb-wa >/dev/null 2>&1
  systemctl restart agsb-wa
elif command -v rc-service >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  cat > /etc/init.d/agsb-wa <<EOF
#!/sbin/openrc-run
description="ArgoSB WARP Argo temporary tunnels"
command="$RUNNER"
command_background=yes
pidfile="/run/agsb-wa.pid"
depend() { need net; }
EOF
  chmod +x /etc/init.d/agsb-wa
  rc-update add agsb-wa default >/dev/null 2>&1
  rc-service agsb-wa restart >/dev/null 2>&1
else
  pkill -f "$WORKDIR/run.sh" 2>/dev/null
  nohup "$RUNNER" > "$WORKDIR/supervisor.log" 2>&1 &
fi

green "正在申请 $N 个 Cloudflare 临时隧道，请稍等..."
waited=0
while [ "$waited" -lt "$((tunnel_wait + 5))" ]; do
  if [ -f "$INFO" ] && grep -q 'vmess://' "$INFO"; then
    break
  fi
  sleep 1
  waited=$((waited+1))
done

green "============================================================"
green "部署流程完成。以下是当前临时隧道节点："
green "============================================================"
if [ -f "$INFO" ]; then
  cat "$INFO"
else
  yellow "临时隧道仍在申请中，稍后执行：bash argosb-nw-warp-argo.sh list"
  yellow "日志目录：$WORKDIR/logs"
fi
yellow "查看节点：bash argosb-nw-warp-argo.sh list"
yellow "卸载：    bash argosb-nw-warp-argo.sh del"
