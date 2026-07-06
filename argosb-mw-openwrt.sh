#!/bin/sh
# =============================================================================
# ArgoSB-MultiWARP (OpenWrt 版) —— 多个本地代理端口，每个端口一套独立 WARP 出口
# 每个端口同时支持 socks5 + http + https（sing-box "mixed" 入站，https 走 http CONNECT）
#
# 内核选型：sing-box（唯一能在“单端口”上同时提供 socks5+http+https 的；并可承载
#           多个 WARP wireguard 出站，按入站端口精确分流到各自出口）
#
# 兼容：OpenWrt / BusyBox ash（纯 POSIX sh，无 bash 数组）
# 依赖：curl、ca-bundle、wireguard-tools(wg)，用 opkg 自动安装；sing-box 自动下载
#
# 全自动适配（换任何机器基本零配置）：
#   - 架构：自动识别 x86_64/arm64/armv7/mips… （sbarch= 可覆盖）
#   - 内核：默认锁静态 sing-box 1.11.11（musl 必需），下载后真跑校验、坏了自愈重下
#   - 下载：镜像优先、官方直连兜底，自动回退
#   - 出网网卡：自动识别物理 WAN（原生 uci/ubus → 默认路由 → 物理口；排除 tun/tap/veth 等）
#   - 全局代理共存：若有 OpenClash/PassWall 等 TUN 全局代理，用 bind_interface 绑 WAN 直连绕过；
#     若本网络直连 WARP 全被封，自动降级为"经全局代理转发"，总之尽量让它能用
#   - 端点端口：自动探测可直连端口（国内常封 2408，自动改 2506/1701/… 等）
#   - DNS：自带 DoH(走 WARP 隧道)解析真实 IP，绕开全局代理 fake-ip(198.18.x)，不改系统 DNS
#
# 用法（环境变量 + 脚本）：
#   num=5 sh argosb-mw-openwrt.sh                 # 开 5 个端口 (默认 20000 起)，各一套 WARP
#   num=5 startport=30000 sh argosb-mw-openwrt.sh
#   ports="20001 20002 30000" sh argosb-mw-openwrt.sh
#   num=5 user=me pass=123 sh argosb-mw-openwrt.sh # 给代理端口加账号密码
#   num=5 uniq=y sh argosb-mw-openwrt.sh            # 强制各端口出口 IP 互不相同(默认 n)
#   以下一般都不用手动设，脚本自动判断；需要时再覆盖：
#   wanif=eth0（出网网卡；wanif=none 关闭绑定）  wgport=2506（端点端口）  wgports="2408 2506 …"
#   dohurl=... ghmirror="https://镜像/"  sbver=1.11.11  sbarch=...  regsleep=3 regretry=12
#
# 管理：sh argosb-mw-openwrt.sh list   /   sh argosb-mw-openwrt.sh del
# =============================================================================
WORKDIR="${WORKDIR:-/etc/agsb-mw}"
BIN="$WORKDIR/sing-box"
CONF="$WORKDIR/config.json"
INFO="$WORKDIR/nodes.txt"

red(){ printf '\033[31m%s\033[0m\n' "$1"; }
green(){ printf '\033[32m%s\033[0m\n' "$1"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$1"; }

# ---------- 彻底卸载（只清理自身，绝不碰其它 sing-box/代理）----------
uninstall_self(){
  green "卸载 ArgoSB-MultiWARP(OpenWrt)（仅清理自身）…"
  if [ -x /etc/init.d/agsb-mw ]; then
    /etc/init.d/agsb-mw stop 2>/dev/null
    /etc/init.d/agsb-mw disable 2>/dev/null
    rm -f /etc/init.d/agsb-mw
    yellow "  ✓ 已移除 procd 服务 agsb-mw"
  fi
  # 只杀命令行含本工作目录 sing-box 的进程（精确匹配，绝不误伤其它 sing-box）
  pids=$(grep -l "$BIN" /proc/[0-9]*/cmdline 2>/dev/null | sed 's#/proc/##;s#/cmdline##')
  for pid in $pids; do kill "$pid" 2>/dev/null; done
  sleep 1
  pids=$(grep -l "$BIN" /proc/[0-9]*/cmdline 2>/dev/null | sed 's#/proc/##;s#/cmdline##')
  for pid in $pids; do kill -9 "$pid" 2>/dev/null; done
  [ -n "$pids" ] && yellow "  ✓ 已结束本脚本的 sing-box 进程"
  [ -d "$WORKDIR" ] && { rm -rf "$WORKDIR"; yellow "  ✓ 已删除工作目录 $WORKDIR"; }
  green "✅ 卸载完成。未触碰其它 sing-box、其它服务、系统配置。"
}

case "$1" in
  del|uninstall) uninstall_self; exit 0 ;;
  list) [ -f "$INFO" ] && cat "$INFO" || red "未安装"; exit 0 ;;
esac

# ---------- 依赖安装（opkg）----------
opkg_ensure(){ # $1=命令 $2=包名
  command -v "$1" >/dev/null 2>&1 && return 0
  if command -v opkg >/dev/null 2>&1; then
    yellow "缺少 $1，opkg 安装 $2 …"
    opkg update >/dev/null 2>&1
    opkg install "$2" >/dev/null 2>&1
  fi
  command -v "$1" >/dev/null 2>&1
}
# curl + CA + wg(密钥生成)
if ! opkg_ensure curl curl; then red "缺少 curl 且自动安装失败，请手动: opkg install curl"; exit 1; fi
command -v opkg >/dev/null 2>&1 && { opkg list-installed 2>/dev/null | grep -q '^ca-bundle ' || opkg install ca-bundle >/dev/null 2>&1; }
HAVE_WG=0; command -v wg >/dev/null 2>&1 && HAVE_WG=1
if [ "$HAVE_WG" = 0 ]; then opkg_ensure wg wireguard-tools >/dev/null 2>&1 && HAVE_WG=1; fi
# 无 wg 则退回 openssl
HAVE_OSSL=0; command -v openssl >/dev/null 2>&1 && HAVE_OSSL=1
if [ "$HAVE_WG" = 0 ] && [ "$HAVE_OSSL" = 0 ]; then
  opkg_ensure openssl openssl-util >/dev/null 2>&1 && HAVE_OSSL=1
fi
if [ "$HAVE_WG" = 0 ] && [ "$HAVE_OSSL" = 0 ]; then
  red "缺少密钥生成工具，请安装其一：opkg install wireguard-tools 或 opkg install openssl-util"; exit 1
fi

# client_id(4字符 base64) → 3 个十进制字节(reserved)，纯 awk 实现，不依赖 od/base64
b64_to_reserved(){
  printf '%s' "$1" | awk '
    BEGIN{ b="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" }
    {
      s=$0
      v0=index(b,substr(s,1,1))-1; v1=index(b,substr(s,2,1))-1
      v2=index(b,substr(s,3,1))-1; v3=index(b,substr(s,4,1))-1
      n=v0*262144 + v1*4096 + v2*64 + v3
      printf "%d,%d,%d", int(n/65536), int((n%65536)/256), (n%65536)%256
    }'
}

mkdir -p "$WORKDIR"

# ---------- 参数 ----------
listen="${listen:-0.0.0.0}"
uniq="${uniq:-n}"
maxtry="${maxtry:-30}"
regretry="${regretry:-12}"
regsleep="${regsleep:-3}"
user="${user:-}"; pass="${pass:-}"
dohurl="${dohurl:-https://1.1.1.1/dns-query}"

# ---------- 智能识别物理 WAN 网卡（用于 bind_interface 直连、绕过 TUN 全局代理）----------
# 关键：OpenClash 等 TUN 全局模式可能把默认路由劫持成 utun，"取默认路由网卡"会错选到 utun。
# 因此按可靠度依次尝试：OpenWrt 原生 WAN 设备 → 默认路由(排除虚拟口) → 任一物理口。
VIRT_RE='tun|tap|utun|wg|clash|singtun|veth|docker|^br-|^lo$|^ifb'
detect_wan(){
  d=""
  # 1) OpenWrt 原生 WAN 物理设备（最可靠，不受 TUN 劫持）
  for net in wan wan6 wwan; do
    d=$(ubus call network.interface.$net status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
    [ -n "$d" ] && break
    d=$(ubus call network.interface.$net status 2>/dev/null | grep -oE '"l3_device":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$d" ] && break
  done
  [ -z "$d" ] && d=$(uci -q get network.wan.device 2>/dev/null)
  [ -z "$d" ] && d=$(uci -q get network.wan.ifname 2>/dev/null)
  # 2) 默认路由网卡，但跳过 tun/tap/utun/veth/docker/br 等虚拟口
  if [ -z "$d" ] || echo "$d" | grep -qiE "$VIRT_RE"; then
    d=""
    for dev in $(ip route show default 2>/dev/null | grep -oE 'dev [^ ]+' | awk '{print $2}'); do
      echo "$dev" | grep -qiE "$VIRT_RE" && continue
      d="$dev"; break
    done
  fi
  # 3) 兜底：第一个带 IPv4 路由的物理网卡
  if [ -z "$d" ]; then
    d=$(ip -4 route show 2>/dev/null | grep -oE 'dev [^ ]+' | awk '{print $2}' | grep -viE "$VIRT_RE" | head -1)
  fi
  echo "$d"
}
if [ -n "${wanif:-}" ]; then
  [ "$wanif" = none ] && wanif="" || :
else
  wanif=$(detect_wan)
fi
BINDLINE=""
[ -n "$wanif" ] && BINDLINE="\"bind_interface\": \"$wanif\", "

# WARP 端点端口：默认自动探测（国内常封 2408，自动改用可直连端口）；wgport= 可强制指定。
wgport="${wgport:-}"
WGPORT_CANDS="${wgports:-2408 2506 1701 500 4500 890 942 988 2371 854 908 968}"

# 端口列表（POSIX：用空格串，不用数组）
if [ -n "$ports" ]; then
  PORT_LIST="$ports"
else
  num="${num:-3}"
  startport="${startport:-20000}"
  PORT_LIST=""; i=0
  while [ "$i" -lt "$num" ]; do PORT_LIST="$PORT_LIST $((startport+i))"; i=$((i+1)); done
fi
set -- $PORT_LIST; N=$#
green "将创建 $N 个代理端口(socks5+http+https)，各绑定一套独立 WARP 出口：$PORT_LIST"
[ -n "$BINDLINE" ] && green "出网网卡：$wanif（自动识别，WARP 绑此口直连、绕过全局代理）" || yellow "未绑定出网网卡：WARP 可能被本机全局代理接管（如需指定 wanif=eth0）"
if [ "$N" -gt 20 ]; then
  yellow "注意：端口较多($N)。CF 对 WARP 注册有限流(429/1015)，脚本会退避重试并按 ${regsleep}s 间隔放慢，"
  yellow "      注册全部账号可能耗时数分钟；$N 条 WireGuard 隧道对路由器内存/CPU 压力较大，请量力。"
fi

# ---------- 本机 IP / WARP 端点 ----------
serverip=$(curl -s4m8 https://api.ipify.org 2>/dev/null || curl -s6m8 https://api64.ipify.org 2>/dev/null)
case "$serverip" in *:*) v6only=1 ;; *) v6only=0 ;; esac
if [ "$v6only" = 1 ]; then WARP_PEER_ADDR="2606:4700:d0::a29f:c001"; else WARP_PEER_ADDR="162.159.192.1"; fi
WARP_PUB="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

# ---------- 下载 sing-box ----------
# 触发下载的条件：不存在/无可执行位，或"存在但实际跑不起来"（例如上次残留了动态链接
# 的 1.13.x 二进制，在 musl 系统上一运行就 not found）——后者也强制重下，脚本自愈。
if [ ! -x "$BIN" ] || ! "$BIN" version >/dev/null 2>&1; then
  [ -e "$BIN" ] && rm -f "$BIN"
  green "下载 sing-box 内核…"
  arch=$(uname -m)
  if [ -n "$sbarch" ]; then SBARCH="$sbarch"; else
    case "$arch" in
      x86_64|amd64) SBARCH=amd64 ;;
      aarch64|arm64) SBARCH=arm64 ;;
      armv7l|armv7) SBARCH=armv7 ;;
      armv6l) SBARCH=armv6 ;;
      mips|mipsel|mips64|mips64el)
        # 端序判断：读 ELF 头 EI_DATA 字节（1=小端 LE，2=大端 BE），不依赖 od
        _ef=/bin/busybox; [ -f "$_ef" ] || _ef=$(command -v sh)
        _ed=$(dd if="$_ef" bs=1 skip=5 count=1 2>/dev/null); _ev=$(printf '%d' "'$_ed" 2>/dev/null)
        if [ "$_ev" = 2 ]; then SBARCH=mips-softfloat; else SBARCH=mipsle-softfloat; fi ;;
      *) SBARCH="" ;;
    esac
  fi
  [ -z "$SBARCH" ] && { red "无法识别架构 $arch，请用 sbarch= 指定(见脚本头注释)"; exit 1; }
  yellow "  目标架构：$SBARCH （不对可用 sbarch= 覆盖）"
  # 版本：默认锁定"静态链接"的 1.11.11。sing-box 1.12+ 官方 linux 构建是动态链接 glibc
  # 并附带 libcronet.so，在 OpenWrt/musl（无 glibc）上运行会报 "not found"。
  ver="${sbver:-1.11.11}"
  if [ "$ver" = latest ]; then
    ver=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -oE '"tag_name":[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"v?([^"]*)"$/\1/')
    [ -z "$ver" ] && ver="1.11.11"
  fi
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${SBARCH}.tar.gz"
  # 下载源自动回退——顺序：自定义镜像(ghmirror) → 公共镜像 → 最后才官方直连 github。
  ok_dl=0
  for base in ${ghmirror:+"$ghmirror"} "https://gh-proxy.com/" "https://ghfast.top/" "https://ghproxy.net/" ""; do
    u="${base}${url}"
    [ -z "$base" ] && yellow "  尝试下载(官方直连)：${u}" || yellow "  尝试下载(镜像)：${u}"
    curl -Lso "$WORKDIR/sb.tgz" --connect-timeout 8 --speed-limit 10240 --speed-time 8 -m 90 "$u" 2>/dev/null
    if gzip -t "$WORKDIR/sb.tgz" 2>/dev/null; then ok_dl=1; green "    ✓ 下载成功"; break; fi
    yellow "    此源不可用，换下一个…"
  done
  if [ "$ok_dl" != 1 ]; then
    red "所有下载源均失败（架构 $SBARCH 版本 $ver）。"
    yellow "  可设 ghmirror=\"https://你的可用镜像/\" 重试，或手动下载解包后把二进制放到 $BIN"
    rm -f "$WORKDIR/sb.tgz"; exit 1
  fi
  ( cd "$WORKDIR" && tar -xzf sb.tgz 2>/dev/null
    mv sing-box-*/sing-box "$BIN" 2>/dev/null
    for f in sing-box-*/libcronet.so; do [ -f "$f" ] && mv "$f" "$WORKDIR/" 2>/dev/null; done
    rm -rf sing-box-*-linux-* sb.tgz )
  chmod +x "$BIN" 2>/dev/null
  [ -x "$BIN" ] || { red "sing-box 解包失败（架构 $SBARCH 版本 $ver）。可手动下载放到 $BIN"; exit 1; }
  if ! "$BIN" version >/dev/null 2>&1; then
    red "sing-box 无法运行（架构=$SBARCH 版本=$ver）。"
    yellow "  多半是该版本为动态链接 glibc（1.12+ 附带 libcronet.so），而本系统(如 OpenWrt)用 musl，缺少 ELF 解释器。"
    yellow "  解决：换用静态版本，例如  sbver=1.11.11 sh \$0  （默认已锁 1.11.11）；架构不符可加 sbarch= 覆盖。"
    rm -f "$BIN"; exit 1
  fi
fi

# ---------- 生成 X25519 密钥对（优先 wg，退回 openssl）----------
gen_keypair(){ # 设置 KP_PRIV KP_PUB
  if [ "$HAVE_WG" = 1 ]; then
    KP_PRIV=$(wg genkey 2>/dev/null)
    KP_PUB=$(printf '%s' "$KP_PRIV" | wg pubkey 2>/dev/null)
  else
    d=$(mktemp -d); openssl genpkey -algorithm X25519 -out "$d/p" 2>/dev/null
    KP_PRIV=$(openssl pkey -in "$d/p" -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A)
    KP_PUB=$(openssl pkey -in "$d/p" -pubout -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A)
    rm -rf "$d"
  fi
  [ -n "$KP_PRIV" ] && [ -n "$KP_PUB" ]
}

# ---------- 注册一套免费 WARP（识别 CF 限流 429/1015 指数退避）----------
# 设置全局 PRIV RESERVED V6ADDR
warp_register(){
  body=$(mktemp); tries=0; wait=5
  while [ "$tries" -lt "$regretry" ]; do
    tries=$((tries+1))
    gen_keypair || { sleep 2; continue; }
    code=$(curl -s -o "$body" -w '%{http_code}' --max-time 15 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
      -H "User-Agent: okhttp/3.12.1" -H "CF-Client-Version: a-6.30-3596" -H "Content-Type: application/json" \
      -d "{\"key\":\"${KP_PUB}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"PC\",\"serial_number\":\"\",\"locale\":\"en_US\"}")
    if [ "$code" = 200 ]; then
      cid=$(grep -o '"client_id":"[^"]*"' "$body" | head -1 | cut -d'"' -f4)
      v6=$(grep -o '"v6":"[0-9a-fA-F:]\{2,\}"' "$body" | head -1 | cut -d'"' -f4)
      if [ -n "$cid" ] && [ -n "$v6" ]; then
        PRIV="$KP_PRIV"; V6ADDR="$v6"
        RESERVED=$(b64_to_reserved "$cid")
        rm -f "$body"; return 0
      fi
    fi
    if [ "$code" = 429 ]; then yellow "      CF 限流(429/1015)，退避 ${wait}s 重试(第 $tries 次)…"
    else yellow "      注册无响应(HTTP=${code:-超时})，${wait}s 后重试(第 $tries 次)…"; fi
    sleep "$wait"; wait=$((wait+5)); [ "$wait" -gt 45 ] && wait=45
  done
  rm -f "$body"; return 1
}

# ---------- 探测可直连的 WARP 端点端口（用当前 $BINDLINE；靠 keepalive 触发握手）----------
warp_probe_port(){ # $1 priv $2 v6 $3 reserved  → 打印可用端口，无则返回1
  for cand in $WGPORT_CANDS; do
    pc=$(mktemp)
    cat > "$pc" <<EOF
{ "log": { "level": "debug" },
  "endpoints": [ { "type": "wireguard", "tag": "pp", ${BINDLINE}"address": [ "172.16.0.2/32", "$2/128" ],
      "private_key": "$1", "peers": [ { "address": "$WARP_PEER_ADDR", "port": $cand,
        "public_key": "$WARP_PUB", "allowed_ips": [ "0.0.0.0/0", "::/0" ], "reserved": [$3],
        "persistent_keepalive_interval": 15 } ] } ],
  "outbounds": [ { "type": "direct", "tag": "d" } ] }
EOF
    "$BIN" run -c "$pc" >"$pc.log" 2>&1 &
    pid=$!; ok=0; k=0
    while [ "$k" -lt 4 ]; do sleep 1; grep -q "received handshake response" "$pc.log" 2>/dev/null && { ok=1; break; }; k=$((k+1)); done
    kill -9 "$pid" 2>/dev/null; rm -f "$pc" "$pc.log"
    [ "$ok" = 1 ] && { echo "$cand"; return 0; }
  done
  return 1
}

# ---------- 探测某账号真实出口 IP（uniq=y 用；临时 sing-box mixed→该 warp）----------
warp_probe_ip(){ # $1=priv $2=v6 $3=reserved  输出出口 IP
  pp=$((41000 + probe_seq)); probe_seq=$((probe_seq+1)); pcfg=$(mktemp)
  cat > "$pcfg" <<EOF
{ "log": { "level": "error" },
  "dns": { "servers": [ { "tag": "d", "address": "$dohurl", "detour": "pw" } ], "strategy": "ipv4_only" },
  "inbounds": [ { "type": "mixed", "tag": "pin", "listen": "127.0.0.1", "listen_port": $pp } ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "endpoints": [ { "type": "wireguard", "tag": "pw", ${BINDLINE}"address": [ "172.16.0.2/32", "$2/128" ],
      "private_key": "$1", "peers": [ { "address": "$WARP_PEER_ADDR", "port": ${WGPORT:-2408},
        "public_key": "$WARP_PUB", "allowed_ips": [ "0.0.0.0/0", "::/0" ], "reserved": [$3] } ] } ],
  "route": { "rules": [ { "inbound": [ "pin" ], "outbound": "pw" } ] } }
EOF
  "$BIN" run -c "$pcfg" >/dev/null 2>&1 &
  ppid=$!; sleep 3; pip=""
  n=0; while [ "$n" -lt 3 ]; do
    pip=$(curl -s --max-time 10 -x "socks5h://127.0.0.1:$pp" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p')
    [ -n "$pip" ] && break; n=$((n+1)); sleep 2
  done
  kill "$ppid" 2>/dev/null; rm -f "$pcfg"; echo "$pip"
}

# ---------- 智能确定"出网方式 + 端点端口"（注册一个引导账号探测，复用给第 1 个口）----------
: > "$INFO"; probe_seq=0
WGPORT="$wgport"; BOOT_OK=0
if [ -z "$WGPORT" ]; then
  yellow "探测可直连的 WARP 端点端口…"
  if warp_register; then
    BOOT_PRIV="$PRIV"; BOOT_V6="$V6ADDR"; BOOT_RES="$RESERVED"; BOOT_OK=1
    # 先试"绑 WAN 直连"（独立、绕过全局代理）
    WGPORT=$(warp_probe_port "$PRIV" "$V6ADDR" "$RESERVED")
    if [ -n "$WGPORT" ]; then
      green "  ✓ 直连端口 $WGPORT（WARP 独立出网，不经其它代理）"
    elif [ -n "$BINDLINE" ]; then
      # 绑定直连全失败 → 自动降级：不绑定，经本机全局代理转发
      yellow "  绑定直连各端口均失败，改试经本机全局代理转发…"
      SAVED_BIND="$BINDLINE"; BINDLINE=""
      WGPORT=$(warp_probe_port "$PRIV" "$V6ADDR" "$RESERVED")
      if [ -n "$WGPORT" ]; then
        yellow "  ⚠ 将经本机全局代理转发出网（端口 $WGPORT，未能直连，WARP 依赖该代理）"
      else
        BINDLINE="$SAVED_BIND"
      fi
    fi
  fi
  if [ -z "$WGPORT" ]; then WGPORT=2408; yellow "  ⚠ 未探测到可用端口，回退 2408"; fi
else
  green "使用指定 WARP 端点端口：$WGPORT"
fi

# ---------- 生成 sing-box 配置 ----------
INBOUNDS=""; ENDPOINTS=""; RULES=""; USED_IPS=""
# 可选账号密码
USERS=""
[ -n "$user" ] && USERS=", \"users\": [ { \"username\": \"$user\", \"password\": \"$pass\" } ]"

[ "$uniq" = y ] && green "已开启出口 IP 唯一校验(uniq=y)：重复则重注册，单端口上限 $maxtry 次。"
idx=0
for p in $PORT_LIST; do
  idx=$((idx+1))
  yellow "  [$idx/$N] 端口 $p 获取 WARP 出口…"
  EGRESS="(未校验)"
  if [ "$uniq" = y ]; then
    t=0; okp=0
    while [ "$t" -lt "$maxtry" ]; do
      t=$((t+1))
      warp_register || { yellow "    第 $t 次注册失败，重试…"; continue; }
      ip=$(warp_probe_ip "$PRIV" "$V6ADDR" "$RESERVED")
      [ -z "$ip" ] && { yellow "    第 $t 次探测失败，重试…"; continue; }
      case " $USED_IPS " in *" $ip "*) yellow "    第 $t 次出口 $ip 重复，重注册…"; continue ;; esac
      USED_IPS="$USED_IPS $ip"; EGRESS="$ip"; okp=1
      green "    ✓ 唯一出口 $ip（$t 次）"; break
    done
    if [ "$okp" != 1 ]; then
      red "❌ 端口 $p 在 $maxtry 次内无法取得唯一出口 IP，已中止（不放行重复）。可减少 num 或加 maxtry=60。"
      pids=$(grep -l "$BIN" /proc/[0-9]*/cmdline 2>/dev/null | sed 's#/proc/##;s#/cmdline##'); for x in $pids; do kill "$x" 2>/dev/null; done
      exit 1
    fi
  else
    if [ "$idx" = 1 ] && [ "$BOOT_OK" = 1 ]; then
      PRIV="$BOOT_PRIV"; V6ADDR="$BOOT_V6"; RESERVED="$BOOT_RES"; BOOT_OK=0  # 复用引导账号
    else
      if ! warp_register; then red "  端口 $p 注册失败，跳过"; continue; fi
    fi
  fi

  INBOUNDS="$INBOUNDS
    { \"type\": \"mixed\", \"tag\": \"in-$idx\", \"listen\": \"$listen\", \"listen_port\": $p$USERS },"
  ENDPOINTS="$ENDPOINTS
    { \"type\": \"wireguard\", \"tag\": \"warp-$idx\", ${BINDLINE}\"address\": [ \"172.16.0.2/32\", \"$V6ADDR/128\" ],
      \"private_key\": \"$PRIV\", \"peers\": [ { \"address\": \"$WARP_PEER_ADDR\", \"port\": $WGPORT,
        \"public_key\": \"$WARP_PUB\", \"allowed_ips\": [ \"0.0.0.0/0\", \"::/0\" ], \"reserved\": [$RESERVED] } ] },"
  RULES="$RULES
      { \"inbound\": [ \"in-$idx\" ], \"outbound\": \"warp-$idx\" },"

  echo "端口 $p  →  独立 WARP 出口 #$idx  出口IP=$EGRESS  (socks5+http+https)" >> "$INFO"
  [ $idx -lt $N ] && sleep "$regsleep"
done

# 去尾逗号
INBOUNDS=$(printf '%s' "$INBOUNDS" | sed '$ s/,$//')
ENDPOINTS=$(printf '%s' "$ENDPOINTS" | sed '$ s/,$//')
RULES=$(printf '%s' "$RULES" | sed '$ s/,$//')

# DNS：用 DoH 走第一条 WARP 隧道(warp-1)解析真实 IP，绕开全局代理(OpenClash 等)的 fake-ip(198.18.x)。
cat > "$CONF" <<EOF
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [ { "tag": "warp-doh", "address": "$dohurl", "detour": "warp-1" } ],
    "strategy": "ipv4_only"
  },
  "inbounds": [ $INBOUNDS
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "endpoints": [ $ENDPOINTS
  ],
  "route": {
    "rules": [ $RULES
    ]
  }
}
EOF

# ---------- 配置自检 ----------
if ! "$BIN" check -c "$CONF" 2>"$WORKDIR/check.err"; then
  red "sing-box 配置自检失败："; cat "$WORKDIR/check.err"; exit 1
fi
green "配置自检通过 ✓"

# ---------- 启动（OpenWrt procd，否则 setsid）----------
if [ -f /etc/rc.common ] && [ -d /etc/init.d ]; then
  cat > /etc/init.d/agsb-mw <<EOF
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
start_service() {
  procd_open_instance
  procd_set_param command $BIN run -c $CONF
  procd_set_param respawn
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF
  chmod +x /etc/init.d/agsb-mw
  /etc/init.d/agsb-mw enable 2>/dev/null
  /etc/init.d/agsb-mw restart 2>/dev/null
else
  for x in $(grep -l "$BIN" /proc/[0-9]*/cmdline 2>/dev/null | sed 's#/proc/##;s#/cmdline##'); do kill "$x" 2>/dev/null; done
  setsid "$BIN" run -c "$CONF" >"$WORKDIR/run.log" 2>&1 &
fi

sleep 2
green "============================================================"
green " 部署完成！$N 个端口，每个都是 socks5 + http + https 三合一"
green " 监听地址：$listen  （局域网其它设备可用 路由器IP:端口 连）"
green " WARP 端点端口：$WGPORT   出网网卡：${wanif:-未绑定(经全局代理)}"
[ -n "$user" ] && green " 认证：用户名 $user / 密码 $pass" || green " 认证：无（如需请用 user= pass= 重新运行）"
green "============================================================"
cat "$INFO"
yellow "查看：sh argosb-mw-openwrt.sh list    卸载：sh argosb-mw-openwrt.sh del"
[ "$listen" = "0.0.0.0" ] && yellow "提示：端口对局域网开放，注意 OpenWrt 防火墙规则，勿暴露到公网。"
