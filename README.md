<div align="center">

# 🚀 xray-warp-multiple

**多入站端口 → 多个「相互独立」的免费 WARP 出口**

一条命令，开出 N 个代理端口，每个端口各走一套**独立注册**的 Cloudflare WARP 账号出网。

![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20OpenWrt-blue)
![Shell](https://img.shields.io/badge/shell-Bash%20%7C%20POSIX%20sh-89e051)
![Core](https://img.shields.io/badge/core-Xray%20%7C%20sing--box-orange)
![Egress](https://img.shields.io/badge/egress-Cloudflare%20WARP-f38020)
![License](https://img.shields.io/badge/license-仅供学习研究-lightgrey)

</div>

---

## ✨ 这是什么

基于甬哥（[yonggekkk/argosbx](https://github.com/yonggekkk/argosbx)）小钢炮脚本的 WARP / WireGuard 出站格式改造而来，**只专注做一件事**：

> 开 **N 个入站端口**，每个端口绑定 **一套单独注册的免费 WARP 账号** 作为出口，端口之间的出口（`reserved` / 私钥 / WireGuard 隧道）**互相独立、互不干扰**。

适合需要「一机多出口、多身份分流」的场景，例如给不同业务/账号分配互不串味的出口通道。

### ⚠️ 关于「出口 IP 是否真的不同」（务必先读）

免费 WARP 的落地 IP 由 Cloudflare 就近数据中心从**有限的地址池**分配：

- 多套密钥能保证**出口通道相互独立**（各自的 WireGuard 隧道、`reserved`、密钥都不同）；
- 但**落地 IP 很可能落在同一区域甚至相同**，无法保证每个端口的出口公网 IP 都不一样。
- 脚本提供 `uniq=y` 开关：逐个端口真实探测出口 IP，重复就重新注册换端点，**强制各端口出口 IP 互不相同**；若本机可用的不同出口不足 N 个，脚本会**明确报错并中止**，绝不给你发重复出口的节点。
- 想要稳定、大量的不同落地 IP，需要 **WARP+（不同 license）** 或**不同上游落地**，免费 WARP 做不到。

---

## 📦 仓库内容

| 文件 | 平台 | 内核 | 入站协议 | 说明 |
| :--- | :--- | :--- | :--- | :--- |
| [`argosb-nw-vps.sh`](argosb-nw-vps.sh) | VPS / Linux | **Xray** | Vmess-ws | 每个端口一套独立 WARP 出口，直连本机 IP、无 TLS |
| [`argosb-nw-warp-argo.sh`](argosb-nw-warp-argo.sh) | VPS / Linux | **Xray + cloudflared** | Vmess-ws over TLS | 每个 WARP 出口各申请一个 Cloudflare 临时隧道，对外生成 `*.trycloudflare.com` 节点 |
| [`argosb-mw-openwrt.sh`](argosb-mw-openwrt.sh) | OpenWrt / BusyBox | **sing-box** | socks5 + http + https（mixed） | 单端口三合一代理，专为软路由 musl 环境适配 |
| [`argosbx.sh`](argosbx.sh) | 通用 | Xray / sing-box | 多协议 | 甬哥原版上游脚本（V26.x），改造基础，供参考 |

> 自制脚本都带独立唯一标识（如 `agsb-mw` / `agsb-wa`），**卸载时只清理自身**，绝不误伤系统里已有的其它 xray / sing-box / vmess / cloudflared 安装。

---

## 🚀 快速开始

> **无需手动下载脚本**，命令里已用 `curl` 拉取远程脚本、直接执行；参数照旧写在最前面的环境变量里。
> **命令里默认走自建加速代理** `https://gh-raw.966788.xyz/xray-warp`（国内可直连）。
> 若该代理失效，把命令里的这段前缀整段替换为下列任一源即可（其余不变）：
> - `https://raw.githubusercontent.com/nue-mic/xray-warp-multiple/main`（GitHub 官方源）
> - `https://cdn.jsdelivr.net/gh/nue-mic/xray-warp-multiple@main`
> - `https://gh-proxy.com/https://raw.githubusercontent.com/nue-mic/xray-warp-multiple/main`

### 一、VPS / Linux 版（Vmess-ws，Xray）

```bash
# 开 5 个 vmess-ws 端口，各配 1 套独立 WARP 出口
num=5 bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-vps.sh)

# 指定起始端口（20000, 20001, 20002 …）
num=3 startport=20000 bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-vps.sh)

# 显式指定端口列表
ports="20001 20002 30000" bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-vps.sh)

# 指定所有端口共用的 UUID（不传则自动生成随机 UUID）
uuid="123e4567-e89b-12d3-a456-426614174000" num=4 bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-vps.sh)

# 强制每个端口出口 IP 互不相同（默认关闭）
uniq=y num=5 bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-vps.sh)
```

**管理命令：**

```bash
bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-vps.sh) list   # 查看节点信息（vmess 分享链接）
bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-vps.sh) del    # 彻底卸载（仅清理自身）
```

### 二、VPS / Linux 临时隧道版（每个 WARP 出口一个 trycloudflare 域名）

这一版把每个本地 vmess-ws 端口都交给一个独立 `cloudflared tunnel --url` 临时隧道暴露出来，不需要 VPS 公网端口入站。节点默认使用**优选域名方式**：`add/server` 写成「随机前缀 + 优选后缀」，`Host/SNI` 仍保持真实 `*.trycloudflare.com` 隧道域名。

脚本还会额外启动一个订阅 HTTP 服务，并再申请一个临时隧道公开订阅：

- `/v2ray`：V2Ray / v2rayN 常用的 base64 VMess 订阅；
- `/clash.yaml`：Clash YAML 订阅。

```bash
# 推荐：开 5 个 WARP 出口，本地端口从 20000 起递增，并申请 5 个 Cloudflare 临时隧道
num=5 startport=20000 bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-warp-argo.sh)

# 指定本地端口列表；每个端口对应一个临时域名
ports="20001 20002 30000" bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-warp-argo.sh)

# 强制每个 WARP 出口 IP 互不相同后再暴露
uniq=y num=5 bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-warp-argo.sh)

# 自定义优选域名后缀池；脚本按节点顺序循环后缀，每个节点随机生成前缀避免缓存
prefer_suffixes="fast.rthink.vip cf.rthink.vip turbo.rthink.vip edge.rthink.vip flare.rthink.vip saas.rthink.vip" num=5 startport=20000 bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-warp-argo.sh)

# 如需退回直接使用 trycloudflare 域名作为 add/server
prefer=n num=5 startport=20000 bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-warp-argo.sh)
```

**自建代理远程执行全命令：**

```bash
num=5 startport=20000 bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-warp-argo.sh)
```

**管理命令：**

```bash
bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-warp-argo.sh) list   # 查看最新临时域名节点
bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-warp-argo.sh) del    # 彻底卸载（仅清理自身）
```

> `trycloudflare.com` 是临时隧道，服务重启后域名会变；每次以 `list` 输出的最新链接为准。端口数很大时会同时运行大量 WARP / cloudflared 进程，VPS 内存与 Cloudflare 临时隧道限流都可能成为瓶颈。
> 默认优选后缀顺序为 `fast.rthink.vip`、`cf.rthink.vip`、`turbo.rthink.vip`、`edge.rthink.vip`、`flare.rthink.vip`、`saas.rthink.vip`，超过 6 个节点后循环使用；每次生成都会换随机前缀。
> 订阅输出会同时给出真实 `trycloudflare.com` 链接和优选域名展示链接。普通订阅 URL 不能像 VMess 节点那样单独指定 Host/SNI，优选订阅是否可直接打开取决于你的优选域名解析/CDN规则；节点本身仍按优选域名方式生成。
> 大批量临时隧道建议先从 `num=10~30` 试起。`num=150` 会同时保活 150 个 `cloudflared` 进程，Cloud Shell / 小内存 VPS 很容易遇到资源瓶颈或 Cloudflare 临时隧道限流；脚本会边申请边刷新 `nodes.txt`，可反复执行 `list` 查看已生成的部分节点。

### 三、OpenWrt / 软路由版（socks5 + http + https，sing-box）

```bash
# OpenWrt 的 BusyBox sh 不支持 bash 的 <(...) 进程替换，故改用「管道」方式：
# 环境变量要写在管道右侧的 sh 前面。

# 开 5 个端口，每个都是 socks5+http+https 三合一，各一套独立 WARP
curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-mw-openwrt.sh | num=5 sh -s

# 指定起始端口
curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-mw-openwrt.sh | num=5 startport=30000 sh -s

# 给代理端口加账号密码
curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-mw-openwrt.sh | num=5 user=me pass=123 sh -s

# 强制各端口出口 IP 互不相同
curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-mw-openwrt.sh | num=5 uniq=y sh -s
```

**管理命令：**

```bash
# 管理命令要走位置参数，管道方式需加 -s --
curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-mw-openwrt.sh | sh -s -- list   # 查看节点信息
curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-mw-openwrt.sh | sh -s -- del    # 彻底卸载（仅清理自身）
```

> OpenWrt 版监听默认 `0.0.0.0`，端口对局域网开放，供内网其它设备用「路由器IP:端口」连接。**请配好防火墙，切勿暴露到公网。**

---

## ⚙️ 环境变量参数

所有配置都通过**环境变量**在命令前传入，无需交互。

### 通用参数（两个脚本都支持）

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `num` | `3` | 端口数量（每个端口一套 WARP 出口） |
| `startport` | VPS 随机 / OpenWrt `20000` | 起始端口，依次递增 |
| `ports` | — | 显式指定端口列表（空格分隔），设置后忽略 `num`/`startport` |
| `uniq` | `n` | `y` 时强制每个端口出口 IP 互不相同；不足则报错中止 |
| `maxtry` | `30` | `uniq=y` 时，单个端口取得唯一出口 IP 的最大重试次数 |
| `regretry` | `12` | 单次 WARP 账号注册的最大重试次数（应对 CF 限流） |
| `regsleep` | `3` | 相邻端口注册之间的间隔秒数（放慢以规避 429/1015 限流） |

### VPS 版（`argosb-nw-vps.sh` / `argosb-nw-warp-argo.sh`）专有

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `uuid` | 随机生成 | 所有端口共用的 Vmess UUID；不传则自动生成，需为合法 8-4-4-4-12 格式（详见下方[「🔑 uuid 用法详解」](#-uuid-用法详解vps-版)） |
| `wspath` | `/argosbmw` / `/argosbwa` | WebSocket 路径；临时隧道版默认 `/argosbwa` |
| `tunnel_wait` | `60` | 仅临时隧道版使用；等待单个 `trycloudflare.com` 域名生成的最长秒数 |
| `sub_port` | 随机 `40000-49999` | 仅临时隧道版使用；本地订阅 HTTP 服务端口 |
| `prefer` | `y` | 仅临时隧道版使用；默认把 `add/server` 改写为优选域名，`prefer=n` 时直接使用 `trycloudflare.com` |
| `prefer_suffixes` | `fast.rthink.vip cf.rthink.vip turbo.rthink.vip edge.rthink.vip flare.rthink.vip saas.rthink.vip` | 仅临时隧道版使用；按节点顺序循环使用这些后缀，前缀每次随机生成 |

### OpenWrt 版（`argosb-mw-openwrt.sh`）专有

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `user` / `pass` | 空（不鉴权） | 给代理端口设置账号密码 |
| `listen` | `0.0.0.0` | 监听地址 |
| `wanif` | 自动识别 | 出网物理网卡；`wanif=none` 关闭绑定 |
| `wgport` | 自动探测 | WARP 端点端口（国内常封 2408，自动改 2506/1701… 等） |
| `wgports` | 内置候选列表 | 端点端口探测候选集 |
| `dohurl` | `https://1.1.1.1/dns-query` | 走 WARP 隧道的 DoH 解析地址 |
| `ghmirror` | — | 自定义 GitHub 下载镜像（内核下载加速/兜底） |
| `sbver` | `1.11.11` | sing-box 版本（锁静态版，musl 必需；`latest` 取最新） |
| `sbarch` | 自动识别 | 强制指定架构（x86_64/arm64/armv7/mips…） |

### 🔑 uuid 用法详解（VPS 版）

`uuid` 是所有 vmess-ws 端口共用的**客户端凭据（节点 id）**。所有端口共用同一个 UUID，客户端只需维护一份凭据即可连接全部节点。

- **默认**：不传 `uuid` 时，脚本自动生成一个随机 UUID（取自 `/proc/sys/kernel/random/uuid`）。
- **传参**：以「环境变量前缀」形式写在命令最前面，**等号两侧不留空格**：

```bash
# 1) 指定一个固定 UUID（推荐从已有客户端复制，或用 uuidgen 生成）
uuid="123e4567-e89b-12d3-a456-426614174000" num=4 bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-vps.sh)

# 2) 现场生成再传入
uuid="$(uuidgen)" num=4 bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-vps.sh)

# 3) 与端口 / 唯一出口等参数组合
uuid="123e4567-e89b-12d3-a456-426614174000" ports="20001 20002" uniq=y bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-vps.sh)
```

- **格式要求**：必须是合法的 `8-4-4-4-12` 十六进制 UUID（如 `123e4567-e89b-12d3-a456-426614174000`），否则客户端无法握手连接。
- **查看已用 UUID**：安装后执行 `bash <(curl -Ls https://gh-raw.966788.xyz/xray-warp/argosb-nw-vps.sh) list`，节点分享链接里即含当前 UUID。
- **适用范围**：`uuid` 仅 VPS 版（Vmess-ws / Xray）使用；OpenWrt 版是 socks5/http 代理，无 UUID 概念，改用 `user` / `pass` 鉴权。

---

## 🔍 工作原理

```
        入站端口 1 ──► WARP 账号 #1 (私钥/reserved 独立) ──► Cloudflare 出口 A
客户端 ─┤ 入站端口 2 ──► WARP 账号 #2 (私钥/reserved 独立) ──► Cloudflare 出口 B
        入站端口 N ──► WARP 账号 #N (私钥/reserved 独立) ──► Cloudflare 出口 …
```

1. **注册 WARP**：为每个端口用 `openssl`/`wg` 生成 X25519 密钥对，POST 到 `api.cloudflareclient.com` 注册一套免费 WARP 账号，解析出 `client_id`（→ `reserved`）与内网 v6 地址。识别 CF 限流（429/1015）并**指数退避重试**。
2. **建立出站**：每套账号生成一个 WireGuard（WARP）出站，各自独立的 `secretKey` / `reserved` / 端点。
3. **精确分流**：路由规则把「入站端口 i」严格绑定到「WARP 出站 i」，端口之间**互不串味**。
4. **可选去重**（`uniq=y`）：启一个临时内核实例，`curl` Cloudflare trace 探测真实出口 IP，重复就换端点重注册，直至各端口出口 IP 全不相同；最终还有一次全局断言兜底。
5. **托管运行**：VPS 用 systemd / OpenRC，OpenWrt 用 procd，非上述环境退回 `nohup`/`setsid` 后台运行，并做配置自检（`xray -test` / `sing-box check`）。

---

## 🧩 依赖与兼容性

- **VPS 版**：硬依赖仅 `curl`、`openssl`（几乎系统自带），JSON 用 `grep` 解析已**不再需要 jq**；解压内核优先 `unzip`，缺失自动回退 `python3`。自动识别 apt / dnf / yum / apk / pacman / zypper 并按需安装。支持 x86_64 / arm64 / armv7 / s390x。
- **OpenWrt 版**：纯 POSIX sh，兼容 BusyBox ash（无 bash 数组）；用 `opkg` 自动装 `curl` / `ca-bundle` / `wireguard-tools`；`sing-box` 自动下载并**真跑校验、坏了自愈重下**。自动识别物理 WAN 网卡（绕过 OpenClash/PassWall 等 TUN 全局代理），自动探测可直连端点端口，自带 DoH 绕开 fake-ip。支持 x86_64 / arm64 / armv7 / mips 等。

---

## ❓ 常见问题

**Q：为什么开了 `uniq=y` 却提示无法取得足够的不同出口 IP？**
A：免费 WARP 出口 IP 从有限池就近分配，你这台机器能摸到的不同出口本就少于 N 个。可减少端口数、调大 `maxtry=60`，或改用 WARP+ / 不同上游落地。

**Q：注册很慢 / 一直提示 429？**
A：Cloudflare 对 WARP 注册接口有限流。端口越多越明显，脚本已自动退避重试并按 `regsleep` 间隔放慢，端口多时耗时数分钟属正常。可适当调大 `regsleep`。

**Q：小内存 VPS / 软路由能开几个？**
A：每个端口都是一条 WireGuard 隧道，N 条隧道对内存、CPU 有实打实的压力，请量力而行，不建议在低配机上开太多。

**Q：卸载会不会误删我别的节点？**
A：不会。两个脚本的一切都带唯一标识 `agsb-mw`（工作目录、服务名、进程命令行），`del` 只按此标识精确清理自身。

---

## 🙏 致谢

- 出站格式与整体思路改造自甬哥的一键无交互脚本 **[yonggekkk/argosbx](https://github.com/yonggekkk/argosbx)**（本仓库 [`argosbx.sh`](argosbx.sh) 为其原版）。
- 出口能力由 **[Cloudflare WARP](https://1.1.1.1/)** 提供。
- 内核：**[XTLS/Xray-core](https://github.com/XTLS/Xray-core)** 与 **[SagerNet/sing-box](https://github.com/SagerNet/sing-box)**。

---

## 📄 免责声明

本仓库脚本仅供**学习、研究与合法的网络技术用途**。请遵守你所在国家/地区的法律法规，以及 Cloudflare WARP 的服务条款。因使用本项目造成的一切后果由使用者自行承担，作者不承担任何责任。
