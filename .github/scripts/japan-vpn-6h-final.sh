#!/usr/bin/env bash
set -Eeuo pipefail

STATE_PATH=".qifu-japan-vpn-current.json"
STAGE="boot"

publish_file() {
  python3 - <<'PY'
import base64, json, os, urllib.request, urllib.error
repo=os.environ['GITHUB_REPOSITORY']
token=os.environ['GH_TOKEN']
path='.qifu-japan-vpn-current.json'
api=f"https://api.github.com/repos/{repo}/contents/{path}"
headers={'Authorization':f'Bearer {token}','Accept':'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28','User-Agent':'qifu-japan-vpn'}
sha=''
try:
    req=urllib.request.Request(api,headers=headers)
    with urllib.request.urlopen(req,timeout=30) as r:
        sha=json.load(r).get('sha','')
except Exception:
    pass
raw=open('/tmp/state.json','rb').read()
payload={'message':'Update Qifu Japan VPN runtime state','content':base64.b64encode(raw).decode()}
if sha: payload['sha']=sha
req=urllib.request.Request(api,data=json.dumps(payload).encode(),headers={**headers,'Content-Type':'application/json'},method='PUT')
with urllib.request.urlopen(req,timeout=30) as r:
    r.read()
PY
}

write_state() {
  python3 - "$@" <<'PY'
import json, os, sys, datetime
status=sys.argv[1]
stage=sys.argv[2]
data={
  'ready': status == 'ready',
  'status': status,
  'stage': stage,
  'run_id': os.environ.get('GITHUB_RUN_ID',''),
  'updated_at': datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')
}
if len(sys.argv)>3 and sys.argv[3]: data['message']=sys.argv[3]
open('/tmp/state.json','w',encoding='utf-8').write(json.dumps(data,ensure_ascii=False,indent=2))
PY
  publish_file
}

on_error() {
  rc=$?
  line=${BASH_LINENO[0]:-unknown}
  set +e
  write_state failed "$STAGE" "exit=${rc}; line=${line}"
  exit "$rc"
}
trap on_error ERR

write_state starting "$STAGE" "GitHub runner allocated"

STAGE="install-runtime"
write_state starting "$STAGE" "Installing OpenVPN, nginx, sing-box and cloudflared"
sudo apt-get update
sudo apt-get install -y openvpn nginx jq curl uuid-runtime python3 ca-certificates

TAG="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name')"
VER="${TAG#v}"
curl -fsSL --retry 5 --retry-delay 2 "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${VER}-linux-amd64.tar.gz" -o /tmp/sing-box.tar.gz
tar -xzf /tmp/sing-box.tar.gz -C /tmp
sudo install -m 0755 "/tmp/sing-box-${VER}-linux-amd64/sing-box" /usr/local/bin/sing-box
curl -fsSL --retry 5 --retry-delay 2 https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cloudflared
sudo install -m 0755 /tmp/cloudflared /usr/local/bin/cloudflared
sing-box version
cloudflared --version

STAGE="fetch-vpngate-japan"
write_state starting "$STAGE" "Fetching VPN Gate CSV and selecting Japan nodes"
printf 'vpn\nvpn\n' >/tmp/vpn-auth
python3 - <<'PY'
import base64,csv,io,json,urllib.request
raw=urllib.request.urlopen('https://www.vpngate.net/api/iphone/',timeout=30).read().decode('utf-8','replace')
all_lines=[x for x in raw.splitlines() if x.strip() and not x.startswith('*')]
header_idx=next((i for i,x in enumerate(all_lines) if x.startswith('#HostName,')),None)
if header_idx is None:
    raise SystemExit('VPN Gate CSV header not found')
lines=all_lines[header_idx:]
lines[0]=lines[0].lstrip('#')
rows=list(csv.DictReader(io.StringIO('\n'.join(lines))))
out=[]
for r in rows:
    if (r.get('CountryShort') or '').upper()!='JP': continue
    blob=r.get('OpenVPN_ConfigData_Base64') or ''
    if not blob: continue
    try: cfg=base64.b64decode(blob).decode('utf-8','replace')
    except Exception: continue
    out.append({'ip':r.get('IP',''),'host':r.get('HostName',''),'speed':int(r.get('Speed') or 0),'ping':int(r.get('Ping') or 999999),'score':int(r.get('Score') or 0),'config':cfg})
out.sort(key=lambda x:(-x['speed'],x['ping'],-x['score']))
if not out: raise SystemExit('No JP OpenVPN candidates found')
json.dump(out[:30],open('/tmp/jp.json','w',encoding='utf-8'))
print('JP candidates:',len(out))
PY

STAGE="connect-japan-exit"
write_state starting "$STAGE" "Trying Japanese OpenVPN exits and verifying country=JP"
ORIGINAL_IP="$(curl -4fsS --max-time 15 https://api.ipify.org || true)"
FOUND=0
for IDX in $(seq 0 29); do
  ITEM="$(jq -r ".[${IDX}] // empty" /tmp/jp.json)"
  [ -n "$ITEM" ] || break
  echo "$ITEM" | jq -r '.config' >/tmp/jp.ovpn
  IP="$(echo "$ITEM" | jq -r '.ip')"
  echo "Trying JP candidate $IDX: $IP"
  sudo pkill openvpn >/dev/null 2>&1 || true
  sleep 2
  if grep -qE '^auth-user-pass([[:space:]]|$)' /tmp/jp.ovpn; then
    sed -i -E 's#^auth-user-pass.*#auth-user-pass /tmp/vpn-auth#' /tmp/jp.ovpn
  else
    echo 'auth-user-pass /tmp/vpn-auth' >>/tmp/jp.ovpn
  fi
  cat >>/tmp/jp.ovpn <<'EOF'
auth-nocache
connect-retry-max 2
connect-timeout 12
script-security 2
EOF
  sudo openvpn --config /tmp/jp.ovpn --daemon qifu-jp --writepid /tmp/openvpn.pid --log /tmp/openvpn.log || true
  READY=0
  for _ in $(seq 1 20); do
    if grep -q 'Initialization Sequence Completed' /tmp/openvpn.log 2>/dev/null; then READY=1; break; fi
    sleep 2
  done
  if [ "$READY" -ne 1 ]; then
    tail -n 15 /tmp/openvpn.log || true
    sudo pkill openvpn >/dev/null 2>&1 || true
    sleep 2
    continue
  fi
  EXIT_IP="$(curl -4fsS --max-time 15 https://api.ipify.org || true)"
  COUNTRY="$(curl -4fsS --max-time 15 https://ifconfig.co/country-iso || true)"
  COUNTRY="$(echo "$COUNTRY" | tr -d '\r\n[:space:]' | tr '[:lower:]' '[:upper:]')"
  if [ "$COUNTRY" != JP ]; then
    COUNTRY="$(curl -4fsS --max-time 15 https://ipapi.co/country/ || true)"
    COUNTRY="$(echo "$COUNTRY" | tr -d '\r\n[:space:]' | tr '[:lower:]' '[:upper:]')"
  fi
  echo "candidate exit=$EXIT_IP country=$COUNTRY"
  if [ -n "$EXIT_IP" ] && [ "$EXIT_IP" != "$ORIGINAL_IP" ] && [ "$COUNTRY" = JP ]; then
    printf '%s' "$EXIT_IP" >/tmp/jp-exit-ip
    printf '%s' "$IP" >/tmp/jp-vpngate-ip
    FOUND=1
    break
  fi
  sudo pkill openvpn >/dev/null 2>&1 || true
  sleep 3
done
[ "$FOUND" -eq 1 ] || { echo 'No verified Japan VPN exit' >&2; false; }

STAGE="start-public-relay"
write_state starting "$STAGE" "Japan exit verified; starting VLESS/WebSocket public relay"
UUID="$(uuidgen)"
printf '%s' "$UUID" >/tmp/uuid
cat >/tmp/server.json <<EOF
{"log":{"level":"info"},"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":10000,"users":[{"uuid":"${UUID}"}],"transport":{"type":"ws","path":"/ws"}}],"outbounds":[{"type":"direct"}]}
EOF
nohup sing-box run -c /tmp/server.json >/tmp/sing-server.log 2>&1 &
echo $! >/tmp/sing-server.pid
sleep 2
kill -0 "$(cat /tmp/sing-server.pid)"

sudo tee /etc/nginx/sites-available/default >/dev/null <<'EOF'
server {
  listen 127.0.0.1:8080;
  location /ws {
    proxy_pass http://127.0.0.1:10000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;
  }
  location = /sub.yaml {
    alias /tmp/sub.yaml;
    default_type text/yaml;
    add_header Cache-Control "no-store" always;
  }
  location = /health { default_type text/plain; return 200 "ok\n"; }
}
EOF
echo '# initializing' >/tmp/sub.yaml
sudo nginx -t
sudo systemctl restart nginx
nohup cloudflared tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:8080 >/tmp/cloudflared.log 2>&1 &
echo $! >/tmp/cloudflared.pid
URL=''
for _ in $(seq 1 90); do
  URL="$(grep -Eo 'https://[A-Za-z0-9-]+\.trycloudflare\.com' /tmp/cloudflared.log | head -n1 || true)"
  [ -n "$URL" ] && break
  sleep 2
done
[ -n "$URL" ] || { cat /tmp/cloudflared.log >&2; false; }
HOST="${URL#https://}"
printf '%s' "$URL" >/tmp/tunnel-url
printf '%s' "$HOST" >/tmp/tunnel-host
cat >/tmp/sub.yaml <<EOF
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: false
proxies:
  - name: "🇯🇵 GitHub临时日本VPN"
    type: vless
    server: ${HOST}
    port: 443
    uuid: ${UUID}
    network: ws
    tls: true
    udp: true
    servername: ${HOST}
    ws-opts:
      path: /ws
      headers:
        Host: ${HOST}
proxy-groups:
  - name: "🇯🇵 日本VPN"
    type: select
    proxies:
      - "🇯🇵 GitHub临时日本VPN"
      - DIRECT
rules:
  - MATCH,🇯🇵 日本VPN
EOF
curl -fsS --retry 12 --retry-delay 2 "${URL}/sub.yaml" | grep -q 'GitHub临时日本VPN'

STAGE="verify-public-path"
write_state starting "$STAGE" "Public subscription is reachable; verifying exact VLESS path exits in Japan"
cat >/tmp/client.json <<EOF
{"log":{"level":"info"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":2080}],"outbounds":[{"type":"vless","server":"${HOST}","server_port":443,"uuid":"${UUID}","tls":{"enabled":true,"server_name":"${HOST}"},"transport":{"type":"ws","path":"/ws","headers":{"Host":"${HOST}"}}}]}
EOF
nohup sing-box run -c /tmp/client.json >/tmp/sing-client.log 2>&1 &
echo $! >/tmp/sing-client.pid
sleep 3
PUBLIC_IP=''
COUNTRY=''
for _ in $(seq 1 15); do
  PUBLIC_IP="$(curl -4fsS --max-time 20 --socks5-hostname 127.0.0.1:2080 https://api.ipify.org || true)"
  COUNTRY="$(curl -4fsS --max-time 20 --socks5-hostname 127.0.0.1:2080 https://ifconfig.co/country-iso || true)"
  COUNTRY="$(echo "$COUNTRY" | tr -d '\r\n[:space:]' | tr '[:lower:]' '[:upper:]')"
  [ -n "$PUBLIC_IP" ] && [ "$COUNTRY" = JP ] && break
  sleep 4
done
[ -n "$PUBLIC_IP" ] && [ "$COUNTRY" = JP ] || { cat /tmp/sing-client.log >&2 || true; false; }
printf '%s' "$PUBLIC_IP" >/tmp/public-ip

STAGE="ready"
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EXPIRES="$(date -u -d '+325 minutes' +%Y-%m-%dT%H:%M:%SZ)"
python3 - <<PY
import json,os
json.dump({
 'ready':True,
 'status':'ready',
 'stage':'ready',
 'subscription_url':'${URL}/sub.yaml',
 'verified_country':'JP',
 'verified_exit_ip':'${PUBLIC_IP}',
 'vpn_gate_server_ip':open('/tmp/jp-vpngate-ip').read(),
 'started_at':'${STARTED}',
 'approx_expires_at':'${EXPIRES}',
 'run_id':os.environ.get('GITHUB_RUN_ID',''),
 'transport':'VLESS+WebSocket+TLS'
},open('/tmp/state.json','w',encoding='utf-8'),ensure_ascii=False,indent=2)
PY
publish_file
cat /tmp/state.json
trap - ERR
