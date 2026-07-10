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
Assert-Contains $content '[ "$cmd" = "list" ]' "supports list command"
Assert-Contains $content '[ "$cmd" = "del" ]' "supports del command"

Write-Host "PASS: static checks"
