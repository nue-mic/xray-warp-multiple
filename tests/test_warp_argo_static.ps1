$ErrorActionPreference = "Stop"

$script = "argosb-nw-warp-argo.sh"

function Assert-Contains($Text, $Pattern, $Message) {
    if ($Text -notmatch [regex]::Escape($Pattern)) {
        throw "FAIL: $Message"
    }
}

if (-not (Test-Path $script)) {
    throw "FAIL: $script does not exist"
}

$content = Get-Content -Raw -Encoding UTF8 $script

Assert-Contains $content 'WORKDIR="$HOME/agsb-wa"' "uses isolated agsb-wa workdir"
Assert-Contains $content 'tunnel --url http://127.0.0.1:' "starts temp cloudflared tunnels per localhost port"
Assert-Contains $content 'trycloudflare.com' "parses trycloudflare temp domains"
Assert-Contains $content '"tls":"tls"' "generates TLS vmess links for cloudflared domains"
Assert-Contains $content 'port":"443"' "generates 443 vmess links for cloudflared domains"
Assert-Contains $content 'outboundTag": "warp-' "routes each inbound to its own WARP outbound"
Assert-Contains $content 'agsb-wa.service' "installs isolated service name"
Assert-Contains $content 'pkill -f "$WORKDIR/cloudflared tunnel' "uninstall only stops own cloudflared processes"
Assert-Contains $content 'printf ''ports="%s"\n''' "quotes port list before sourcing meta.env"
Assert-Contains $content 'prefer="${prefer:-y}"' "uses preferred domain mode by default"
Assert-Contains $content 'DEFAULT_PREFER_SUFFIXES=' "ships a default preferred domain suffix pool"
Assert-Contains $content 'prefer_suffixes="${prefer_suffixes:-$DEFAULT_PREFER_SUFFIXES}"' "supports overriding preferred suffix pool"
Assert-Contains $content 'random_label()' "generates random preferred domain prefix"
Assert-Contains $content 'pick_prefer_suffix()' "picks preferred suffix by node order"
Assert-Contains $content 'od -An -N4 -tx4 /dev/urandom' "uses urandom for preferred domain prefix"
Assert-Contains $content '"$server_domain" "$uuid" "$domain" "$wspath" "$domain"' "uses preferred add with trycloudflare host and sni"
Assert-Contains $content 'SUBDIR="$WORKDIR/sub"' "creates subscription directory"
Assert-Contains $content 'V2RAY_SUB="$SUBDIR/v2ray"' "writes v2ray subscription"
Assert-Contains $content 'CLASH_SUB="$SUBDIR/clash.yaml"' "writes clash subscription"
Assert-Contains $content 'python3 -m http.server' "serves subscriptions over local HTTP"
Assert-Contains $content 'sub-argo.log' "starts a separate subscription tunnel"
Assert-Contains $content 'V2Ray' "prints v2ray subscription links"
Assert-Contains $content '/clash.yaml' "prints clash subscription links"
Assert-Contains $content '[ "$cmd" = "list" ]' "supports list command"
Assert-Contains $content '[ "$cmd" = "del" ]' "supports del command"

Write-Host "PASS: static checks"
