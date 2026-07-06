#!/bin/bash
# =============================================================================
# ArgoSB-MultiWARP  —  Vmess-ws 多入栈端口 → 多个独立 WARP 出口
# 基于甬哥 argosbx 的 WARP/xray 出站格式改造，专注实现：
#   N 个 Vmess-ws 端口，每个端口走一套“独立注册的免费 WARP 账号”出站。
#
# 说明（重要）：
#   免费 WARP 的落地 IP 由 Cloudflare 就近数据中心分配，多套密钥能保证
#   “出口互相独立、reserved/密钥各不相同”，但**落地 IP 很可能同区域甚至相近**，
#   无法保证每个出口 IP 完全不同。若要真正不同的落地 IP，需 WARP+ 或不同上游。
#
# 用法示例：
#   num=5 bash argosb-multiwarp.sh                 # 开 5 个 vmess-ws 端口，各配 1 套 WARP
#   num=3 startport=20000 bash argosb-multiwarp.sh # 指定起始端口 20000,20001,20002
#   ports="20001 20002 30000" bash argosb-multiwarp.sh  # 显式指定端口列表
#   uuid="xxxx-..." num=4 bash argosb-multiwarp.sh # 指定统一 UUID
#   uniq=y num=5 bash argosb-multiwarp.sh          # 强制每个端口出口 IP 互不相同（默认关闭）
#
# 管理：
#   bash argosb-multiwarp.sh list   # 查看节点信息
#   bash argosb-multiwarp.sh del    # 卸载
# =============================================================================
set -o pipefail
export LANG=en_US.UTF-8
WORKDIR="$HOME/agsb-mw"
BIN="$WORKDIR/xray"
CONF="$WORKDIR/xr.json"
INFO="$WORKDIR/nodes.txt"
META="$WORKDIR/meta.env"

red(){ echo -e "\033[31m$1\033[0m"; }
green(){ echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }

# =============================================================================
# 彻底卸载（只清理本脚本自身，绝不碰 argosbx 或其它 vmess-ws/xray）
# 安全边界：本脚本的一切都带唯一标识 "agsb-mw"（工作目录 ~/agsb-mw、
# systemd/openrc 服务名 agsb-mw、进程命令行含 ~/agsb-mw/xray）。
# 卸载时只按这个唯一标识精确匹配，不会误伤 ~/agsb、~/agsbx 等其它安装。
# =============================================================================
uninstall_self(){
  local removed=0
  green "开始彻底卸载 ArgoSB-MultiWARP（仅清理自身）…"

  # 1) systemd 服务：仅 agsb-mw
  if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/agsb-mw.service ]; then
    systemctl stop agsb-mw 2>/dev/null
    systemctl disable agsb-mw 2>/dev/null
    rm -f /etc/systemd/system/agsb-mw.service
    systemctl daemon-reload 2>/dev/null
    yellow "  ✓ 已移除 systemd 服务 agsb-mw"; removed=1
  fi

  # 2) openrc 服务：仅 agsb-mw
  if command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/agsb-mw ]; then
    rc-service agsb-mw stop 2>/dev/null
    rc-update del agsb-mw default 2>/dev/null
    rm -f /etc/init.d/agsb-mw
    yellow "  ✓ 已移除 openrc 服务 agsb-mw"; removed=1
  fi

  # 3) 残留进程：只杀命令行里含本脚本工作目录的 xray（精确到 ~/agsb-mw/）
  #    绝不用泛匹配 "xray"/"vmess"，因此不会误杀 argosbx 或别的脚本的进程。
  local pids
  pids=$(pgrep -f "$WORKDIR/xray" 2>/dev/null)
  if [ -n "$pids" ]; then
    echo "  即将结束以下进程（均属于 agsb-mw）："
    for pid in $pids; do
      echo "    PID $pid : $(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | cut -c1-90)"
    done
    kill $pids 2>/dev/null; sleep 1
    pids=$(pgrep -f "$WORKDIR/xray" 2>/dev/null)
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    yellow "  ✓ 已结束 agsb-mw 的 xray 进程"; removed=1
  fi

  # 4) 工作目录：仅 ~/agsb-mw（含 xray 二进制、配置、节点信息）
  if [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
    yellow "  ✓ 已删除工作目录 $WORKDIR"; removed=1
  fi

  # 5) 主动声明未触碰的东西，让用户放心
  echo
  if [ "$removed" = 1 ]; then
    green "✅ 彻底卸载完成，仅清理了 ArgoSB-MultiWARP 自身。"
  else
    yellow "未发现 ArgoSB-MultiWARP 的任何安装痕迹（可能已卸载或从未安装）。"
  fi
  echo "   下列内容未做任何改动：其它脚本的 xray/vmess-ws、~/agsb、~/agsbx、.bashrc、crontab、系统依赖。"
}

# ---------- 卸载 / 列表 ----------
cmd="$1"
if [ "$cmd" = "del" ] || [ "$cmd" = "uninstall" ]; then
  uninstall_self; exit 0
fi
if [ "$cmd" = "list" ]; then
  [ -f "$INFO" ] && cat "$INFO" || red "未安装"
  exit 0
fi

# ---------- 依赖检查（自动安装）----------
# 硬依赖仅 curl、openssl（几乎所有系统自带）；JSON 用 grep 解析，已不再需要 jq；
# 解压 xray 用 unzip，缺失时自动回退 python3，二者都没有才尝试装 unzip。
detect_pm(){
  if command -v apt-get >/dev/null 2>&1; then echo apt;
  elif command -v dnf >/dev/null 2>&1; then echo dnf;
  elif command -v yum >/dev/null 2>&1; then echo yum;
  elif command -v apk >/dev/null 2>&1; then echo apk;
  elif command -v pacman >/dev/null 2>&1; then echo pacman;
  elif command -v zypper >/dev/null 2>&1; then echo zypper;
  else echo none; fi
}
pm_install(){ # $1=包管理器 其余=包名
  local pm=$1; shift
  case "$pm" in
    # apt：先直接装（省内存），失败再 update 后重试
    apt)    apt-get install -y --no-install-recommends "$@" >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1; apt-get install -y --no-install-recommends "$@" >/dev/null 2>&1; } ;;
    dnf)    dnf install -y "$@" >/dev/null 2>&1 ;;
    yum)    yum install -y "$@" >/dev/null 2>&1 ;;
    apk)    apk add --no-cache "$@" >/dev/null 2>&1 ;;
    pacman) pacman -Sy --noconfirm "$@" >/dev/null 2>&1 ;;
    zypper) zypper --non-interactive install "$@" >/dev/null 2>&1 ;;
  esac
}
SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"
PM=$(detect_pm)
ensure_pkg(){ # $1=命令名 $2=包名(默认同命令名)
  local cmd="$1" pkg="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  [ "$PM" = none ] && { red "缺少依赖：$cmd，且未识别到包管理器，请手动安装后重试"; return 1; }
  yellow "缺少依赖 $cmd，正在自动安装…"
  if [ -n "$SUDO" ]; then $SUDO bash -c "$(declare -f pm_install); pm_install $PM $pkg"; else pm_install "$PM" "$pkg"; fi
  command -v "$cmd" >/dev/null 2>&1 && { green "  ✓ $cmd 已安装"; return 0; } || { red "自动安装 $cmd 失败，请手动安装：$pkg"; return 1; }
}
for c in curl openssl; do ensure_pkg "$c" || exit 1; done

mkdir -p "$WORKDIR"

# ---------- 参数 ----------
uuid="${uuid:-$(cat /proc/sys/kernel/random/uuid)}"
wspath="${wspath:-/argosbmw}"
uniq="${uniq:-n}"           # 是否强制每个出口 IP 唯一（y/n），默认 n（不检测）；需要时传 uniq=y 开启
maxtry="${maxtry:-30}"      # uniq=y 时，为单个端口取得唯一出口 IP 的最大重试次数
# 端口列表
if [ -n "$ports" ]; then
  PORT_LIST=($ports)
else
  num="${num:-3}"
  startport="${startport:-$(( (RANDOM % 20000) + 20000 ))}"
  PORT_LIST=()
  for i in $(seq 0 $((num-1))); do PORT_LIST+=( $((startport+i)) ); done
fi
N=${#PORT_LIST[@]}
green "将创建 $N 个 Vmess-ws 端口，各绑定一套独立 WARP 出口：${PORT_LIST[*]}"
if [ "$N" -gt 20 ]; then
  yellow "注意：端口数较多（$N）。CF 对 WARP 注册接口有限流(429/1015)，脚本会自动退避重试并按 ${regsleep:-3}s 间隔放慢，"
  yellow "      因此注册全部账号可能耗时数分钟；且 $N 条 WireGuard 隧道对小内存 VPS 压力较大，请确保机器扛得住。"
  yellow "      如只是想多开端口、不在意各出口是否独立，可考虑其它方案；继续将按上述节奏进行。"
fi

# ---------- 获取本机 IP ----------
serverip=$(curl -s4m8 https://api.ipify.org 2>/dev/null || curl -s6m8 https://api64.ipify.org 2>/dev/null)
if echo "$serverip" | grep -q ':'; then SNI_IP="[$serverip]"; v6only=1; else SNI_IP="$serverip"; v6only=0; fi
[ -z "$serverip" ] && { red "无法获取本机公网 IP"; exit 1; }

# WARP peer 端点池：轮换不同入口 anycast IP，提高各账号落地到不同出口 IP 的概率
if [ "$v6only" = 1 ]; then
  ENDPOINT_POOL="[2606:4700:d0::a29f:c001]:2408 [2606:4700:d0::a29f:c005]:2408 [2606:4700:d0::a29f:c010]:2408 [2606:4700:d0::a29f:c019]:2408 [2606:4700:d0::a29f:c025]:2408"
else
  ENDPOINT_POOL="162.159.192.1:2408 162.159.193.10:2408 188.114.98.1:2408 188.114.99.1:2408 162.159.192.5:2408 162.159.193.5:2408 188.114.98.224:2408 162.159.192.9:2408"
fi
EP_ARR=($ENDPOINT_POOL); EP_N=${#EP_ARR[@]}
WARP_ENDPOINT="${EP_ARR[0]}"   # uniq=n 时的默认端点

# ---------- 下载 xray ----------
if [ ! -x "$BIN" ]; then
  green "下载 xray 内核…"
  case "$(uname -m)" in
    x86_64|amd64) XARCH="64" ;;
    aarch64|arm64) XARCH="arm64-v8a" ;;
    armv7l) XARCH="arm32-v7a" ;;
    s390x) XARCH="s390x" ;;
    *) red "不支持的架构 $(uname -m)"; exit 1 ;;
  esac
  # 无 jq 解析最新版本号（GitHub JSON 带空格，用容错正则）
  ver=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep -oE '"tag_name":[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"(v[^"]*)"$/\1/')
  [ -z "$ver" ] && ver="v25.6.8"
  curl -Lso "$WORKDIR/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-${XARCH}.zip"
  # 解压：优先 unzip，其次 python3，最后尝试安装 unzip
  if command -v unzip >/dev/null 2>&1; then
    (cd "$WORKDIR" && unzip -oq xray.zip xray)
  elif command -v python3 >/dev/null 2>&1; then
    (cd "$WORKDIR" && python3 -c "import zipfile; zipfile.ZipFile('xray.zip').extract('xray')")
  else
    ensure_pkg unzip && (cd "$WORKDIR" && unzip -oq xray.zip xray) || { red "无法解压 xray.zip（缺 unzip 且无 python3）"; exit 1; }
  fi
  chmod +x "$BIN" 2>/dev/null; rm -f "$WORKDIR/xray.zip"
  [ -x "$BIN" ] || { red "xray 下载失败"; exit 1; }
fi

# ---------- 注册一套免费 WARP 账号（识别 CF 限流 429/1015 并指数退避）----------
# 输出：全局变量 PRIV RESERVED V6ADDR
warp_register(){
  local kd priv pub body code cid v6 tries=0 wait=5
  body=$(mktemp)
  while [ $tries -lt "${regretry:-12}" ]; do
    tries=$((tries+1))
    kd=$(mktemp -d)
    openssl genpkey -algorithm X25519 -out "$kd/p.pem" 2>/dev/null
    # 原始私钥 = DER 编码末 32 字节（无需 xxd）
    priv=$(openssl pkey -in "$kd/p.pem" -outform DER 2>/dev/null | tail -c 32 | base64 -w0)
    pub=$(openssl pkey -in "$kd/p.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0)
    rm -rf "$kd"
    code=$(curl -s -o "$body" -w '%{http_code}' --max-time 15 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
      -H "User-Agent: okhttp/3.12.1" -H "CF-Client-Version: a-6.30-3596" -H "Content-Type: application/json" \
      -d "{\"key\":\"${pub}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"PC\",\"serial_number\":\"\",\"locale\":\"en_US\"}")
    if [ "$code" = 200 ]; then
      # 无 jq 解析：client_id 与接口 v6 地址（端点 v6 带方括号，字符类不含 [ 故不会误匹配）
      cid=$(grep -o '"client_id":"[^"]*"' "$body" | head -1 | cut -d'"' -f4)
      v6=$(grep -o '"v6":"[0-9a-fA-F:]\{2,\}"' "$body" | head -1 | cut -d'"' -f4)
      if [ -n "$cid" ] && [ -n "$v6" ]; then
        PRIV="$priv"
        # reserved = client_id 解码后的十进制字节（用 od，无需 xxd）
        RESERVED=$(echo "$cid" | base64 -d 2>/dev/null | od -An -tu1 | tr -s ' ' | sed 's/^ //;s/ $//;s/ /,/g')
        V6ADDR="$v6"
        rm -f "$body"; return 0
      fi
    fi
    # 被 CF 限流(429/1015)或网络异常：指数退避后重试
    if [ "$code" = 429 ]; then
      yellow "      CF 限流(429/1015)，退避 ${wait}s 后重试（第 $tries 次）…"
    else
      yellow "      注册无响应(HTTP=${code:-超时})，${wait}s 后重试（第 $tries 次）…"
    fi
    sleep "$wait"; wait=$((wait+5)); [ $wait -gt 45 ] && wait=45
  done
  rm -f "$body"; return 1
}

# ---------- 探测某套 WARP 账号的真实出口 IP ----------
# 起一个临时 xray（socks 入站 → 该 wireguard 出站），curl 取出口 IP
# 参数：$1=私钥 $2=v6地址 $3=reserved $4=端点   输出：出口 IP（失败则空）
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
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  rm -f "$cfg"
  echo "$ip"
}

# ---------- 为一个端口取得“出口 IP 唯一”的 WARP 账号 ----------
# 使用全局 USED_IPS 去重；成功时设置 PRIV/RESERVED/V6ADDR/ENDPT/EGRESS 并把 IP 记入 USED_IPS
acquire_unique(){
  local t=0 ep egress
  while [ $t -lt "$maxtry" ]; do
    t=$((t+1))
    if ! warp_register; then yellow "    第 $t 次：账号注册失败，重试…"; sleep 2; continue; fi
    ep="${EP_ARR[$(( (t-1) % EP_N ))]}"   # 轮换端点，增加出口多样性
    egress=$(warp_probe_ip "$PRIV" "$V6ADDR" "$RESERVED" "$ep")
    if [ -z "$egress" ]; then yellow "    第 $t 次：出口探测失败（WARP 握手/网络？），重试…"; continue; fi
    if echo " $USED_IPS " | grep -q " $egress "; then
      yellow "    第 $t 次：出口 IP $egress 与已有重复，重新注册…"; continue
    fi
    ENDPT="$ep"; EGRESS="$egress"; USED_IPS="$USED_IPS $egress"
    green "    ✓ 取得唯一出口 IP：$egress（尝试 $t 次）"
    return 0
  done
  return 1
}
# ---------- 生成 xray 配置 ----------
INBOUNDS=""; OUTBOUNDS=""; RULES=""; USED_IPS=""
: > "$INFO"; : > "$META"
echo "uuid=$uuid" >> "$META"; echo "wspath=$wspath" >> "$META"

if [ "$uniq" = y ]; then
  green "开始注册 WARP 并逐个校验出口 IP 唯一（重复则重新注册，单端口上限 $maxtry 次）…"
else
  yellow "已关闭出口 IP 唯一校验（uniq=n）：不同端口出口 IP 可能相同。"
fi
idx=0
for p in "${PORT_LIST[@]}"; do
  idx=$((idx+1))
  yellow "  [$idx/$N] 端口 $p 获取 WARP 出口…"
  if [ "$uniq" = y ]; then
    if ! acquire_unique; then
      red "❌ 端口 $p 在 $maxtry 次尝试内无法取得与其它端口都不同的出口 IP。"
      red "   原因：免费 WARP 出口 IP 由 Cloudflare 就近机房从有限池分配，本机可用的不同出口不足 $N 个。"
      red "   已中止安装（不会给你发重复出口的节点）。建议：减少端口数（如 num=$((idx-1))）、"
      red "   提高上限（maxtry=60）、或改用 WARP+（不同 license）/不同上游落地以获得更多不同出口。"
      pkill -f "$BIN run -c" 2>/dev/null
      exit 1
    fi
  else
    if ! warp_register; then red "  端口 $p 的 WARP 注册失败，跳过"; continue; fi
    ENDPT="$WARP_ENDPOINT"; EGRESS="(未校验)"
  fi

  # inbound
  INBOUNDS+='
    {
      "tag": "vmess-'"$idx"'",
      "listen": "::",
      "port": '"$p"',
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "'"$uuid"'" } ] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "'"$wspath"'" }
      }
    },'

  # outbound (wireguard / WARP)
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

  # routing rule: inbound -> its own warp
  RULES+='
      { "type": "field", "inboundTag": ["vmess-'"$idx"'"], "outboundTag": "warp-'"$idx"'" },'

  # 记录节点分享链接（vmess-ws，直连本机 IP，无 TLS）
  vmess_json=$(printf '{"v":"2","ps":"MW-warp-%s-%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"","path":"%s","tls":"","sni":"","alpn":""}' "$idx" "$p" "$serverip" "$p" "$uuid" "$wspath")
  vmess_link="vmess://$(echo -n "$vmess_json" | base64 -w0)"
  echo "端口 $p  →  独立 WARP 出口 #$idx  出口IP=$EGRESS  (reserved=[$RESERVED])" >> "$INFO"
  echo "$vmess_link" >> "$INFO"
  echo "" >> "$INFO"
  # 节流：注册之间留间隔，避免触发 CF 限流(429/1015)。端口越多间隔越有必要。
  [ $idx -lt $N ] && sleep "${regsleep:-3}"
done

# 去掉尾逗号，拼装完整配置
INBOUNDS="${INBOUNDS%,}"
OUTBOUNDS="${OUTBOUNDS%,}"
RULES="${RULES%,}"

# ---------- 最终唯一性断言（uniq=y 时兜底，绝不放行重复出口）----------
if [ "$uniq" = y ]; then
  total=$(echo $USED_IPS | wc -w)
  distinct=$(echo $USED_IPS | tr ' ' '\n' | sort -u | grep -c .)
  if [ "$total" -ne "$N" ] || [ "$distinct" -ne "$N" ]; then
    red "❌ 最终校验未通过：期望 $N 个各不相同的出口 IP，实际 total=$total distinct=$distinct，已中止。"
    pkill -f "$BIN run -c" 2>/dev/null; exit 1
  fi
  green "✓ 最终校验通过：$N 个端口的出口 IP 全部互不相同（$USED_IPS ）"
fi

cat > "$CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [ $INBOUNDS
  ],
  "outbounds": [ $OUTBOUNDS ,
    { "protocol": "freedom", "tag": "direct" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [ $RULES
    ]
  }
}
EOF

# ---------- 配置自检 ----------
if ! "$BIN" run -test -c "$CONF" >/dev/null 2>"$WORKDIR/test.err"; then
  red "xray 配置自检失败："; cat "$WORKDIR/test.err"; exit 1
fi
green "配置自检通过 ✓"

# ---------- 启动 ----------
if pidof systemd >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  cat > /etc/systemd/system/agsb-mw.service <<EOF
[Unit]
Description=ArgoSB MultiWARP (xray)
After=network.target
[Service]
Type=simple
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable agsb-mw >/dev/null 2>&1; systemctl restart agsb-mw
elif command -v rc-service >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  cat > /etc/init.d/agsb-mw <<EOF
#!/sbin/openrc-run
description="ArgoSB MultiWARP (xray)"
command="$BIN"
command_args="run -c $CONF"
command_background=yes
pidfile="/run/agsb-mw.pid"
depend() { need net; }
EOF
  chmod +x /etc/init.d/agsb-mw
  rc-update add agsb-mw default >/dev/null 2>&1
  rc-service agsb-mw restart >/dev/null 2>&1
else
  pkill -f "$BIN" 2>/dev/null
  nohup "$BIN" run -c "$CONF" >"$WORKDIR/run.log" 2>&1 &
fi

sleep 2
green "============================================================"
green " 部署完成！共 $N 个 Vmess-ws 端口，各绑定一套独立 WARP 出口"
green "============================================================"
cat "$INFO"
yellow "查看节点：bash argosb-multiwarp.sh list"
yellow "卸载：    bash argosb-multiwarp.sh del"
yellow "默认不校验出口 IP 唯一（uniq=n）。如需强制每个端口出口 IP 互不相同：加 uniq=y（可配 maxtry=60）。"
