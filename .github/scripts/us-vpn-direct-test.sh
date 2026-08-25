#!/usr/bin/env bash
set -Eeuo pipefail
STAGE="boot"
STATE_PATH=".qifu-us-vpn-current.json"
SUB_PATH="subscriptions/us-test.yaml"

put_repo_file(){
  local path="$1" local_file="$2" message="$3"
  PATH_NAME="$path" LOCAL_FILE="$local_file" COMMIT_MESSAGE="$message" python3 - <<'PY'
import base64,json,os,time,urllib.error,urllib.request
repo=os.environ['GITHUB_REPOSITORY']; token=os.environ['GH_TOKEN']; path=os.environ['PATH_NAME']
api=f'https://api.github.com/repos/{repo}/contents/{path}'
h={'Authorization':f'Bearer {token}','Accept':'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28','User-Agent':'qifu-us-vpn-test'}
raw=open(os.environ['LOCAL_FILE'],'rb').read()
for attempt in range(1,7):
    sha=''
    try:
        with urllib.request.urlopen(urllib.request.Request(api,headers=h),timeout=30) as r: sha=json.load(r).get('sha','')
    except urllib.error.HTTPError as exc:
        if exc.code != 404: print(f'GET {path} attempt {attempt}: {exc}', flush=True)
    except Exception as exc:
        print(f'GET {path} attempt {attempt}: {exc}', flush=True)
    payload={'message':os.environ['COMMIT_MESSAGE'],'content':base64.b64encode(raw).decode('ascii')}
    if sha: payload['sha']=sha
    req=urllib.request.Request(api,data=json.dumps(payload).encode(),headers={**h,'Content-Type':'application/json'},method='PUT')
    try:
        with urllib.request.urlopen(req,timeout=30) as r:r.read()
        break
    except urllib.error.HTTPError as exc:
        if exc.code not in (409,422) or attempt == 6: raise
        time.sleep(min(2*attempt,8))
PY
}

publish_state(){
  STATUS="$1" STAGE_NAME="$2" MESSAGE="${3:-}" python3 - <<'PY'
import datetime,json,os
x={'ready':os.environ['STATUS']=='ready','status':os.environ['STATUS'],'stage':os.environ['STAGE_NAME'],'run_id':os.environ.get('GITHUB_RUN_ID',''),'updated_at':datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z'),'message':os.environ.get('MESSAGE','')}
open('/tmp/us-state.json','w',encoding='utf-8').write(json.dumps(x,ensure_ascii=False,indent=2))
PY
  put_repo_file "$STATE_PATH" /tmp/us-state.json "Update US VPN test state"
}

fail(){ rc=$?; set +e; publish_state failed "$STAGE" "exit=${rc}; line=${BASH_LINENO[0]:-unknown}"; exit "$rc"; }
trap fail ERR

STAGE="install-runtime"; publish_state starting "$STAGE" "Installing US test runtime"
sudo apt-get update
sudo apt-get install -y nginx jq curl uuid-runtime python3 ca-certificates
TAG="$(curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -H "Authorization: Bearer ${GH_TOKEN}" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' -H 'User-Agent: qifu-us-vpn-test' https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -er '.tag_name')"
VER="${TAG#v}"
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${VER}-linux-amd64.tar.gz" -o /tmp/sb.tgz
tar -xzf /tmp/sb.tgz -C /tmp
sudo install -m0755 "/tmp/sing-box-${VER}-linux-amd64/sing-box" /usr/local/bin/sing-box
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cloudflared
sudo install -m0755 /tmp/cloudflared /usr/local/bin/cloudflared

STAGE="verify-us-runner"; publish_state starting "$STAGE" "Verifying GitHub runner direct exit is US"
DIRECT_IP="$(curl -4fsS --max-time 15 https://api.ipify.org || true)"
COUNTRY="$(curl -4fsS --max-time 15 https://ifconfig.co/country-iso || true)"; COUNTRY="$(echo "$COUNTRY"|tr -d '\r\n[:space:]'|tr '[:lower:]' '[:upper:]')"
if [ "$COUNTRY" != US ]; then COUNTRY="$(curl -4fsS --max-time 15 https://ipapi.co/country/ || true)"; COUNTRY="$(echo "$COUNTRY"|tr -d '\r\n[:space:]'|tr '[:lower:]' '[:upper:]')"; fi
[ -n "$DIRECT_IP" ] && [ "$COUNTRY" = US ] || { echo "Runner direct exit is not US: ip=${DIRECT_IP} country=${COUNTRY}" >&2; false; }
printf '%s' "$DIRECT_IP" >/tmp/us-direct-ip

STAGE="start-public-relay"; publish_state starting "$STAGE" "Starting US VLESS WebSocket Cloudflare relay"
UUID="$(uuidgen)"; printf '%s' "$UUID" >/tmp/uuid
cat >/tmp/server.json <<EOF
{"log":{"level":"info"},"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":10000,"users":[{"uuid":"${UUID}"}],"transport":{"type":"ws","path":"/ws"}}],"outbounds":[{"type":"direct"}]}
EOF
nohup sing-box run -c /tmp/server.json >/tmp/sing-server.log 2>&1 & echo $! >/tmp/sing-server.pid
sleep 2; kill -0 "$(cat /tmp/sing-server.pid)"
sudo tee /etc/nginx/sites-available/default >/dev/null <<'EOF'
server { listen 127.0.0.1:8080;
 location /ws { proxy_pass http://127.0.0.1:10000; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; proxy_read_timeout 3600s; }
 location = /sub.yaml { alias /tmp/sub.yaml; default_type text/yaml; add_header Cache-Control "no-store" always; }
 location = /health { default_type text/plain; return 200 "ok\n"; }
}
EOF
echo '# initializing' >/tmp/sub.yaml
sudo nginx -t; sudo systemctl restart nginx
nohup cloudflared tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:8080 >/tmp/cloudflared.log 2>&1 & echo $! >/tmp/cloudflared.pid
URL=''; for _ in $(seq 1 90); do URL="$(grep -Eo 'https://[A-Za-z0-9-]+\.trycloudflare\.com' /tmp/cloudflared.log|head -n1||true)"; [ -n "$URL" ]&&break; sleep 2; done
[ -n "$URL" ] || { cat /tmp/cloudflared.log >&2; false; }
HOST="${URL#https://}"; printf '%s' "$URL" >/tmp/tunnel-url
cat >/tmp/sub.yaml <<EOF
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: false
proxies:
  - name: "🇺🇸 GitHub临时美国VPN"
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
  - name: "🇺🇸 美国VPN"
    type: select
    proxies: ["🇺🇸 GitHub临时美国VPN", DIRECT]
rules:
  - MATCH,🇺🇸 美国VPN
EOF

STAGE="wait-public-dns"; publish_state starting "$STAGE" "Waiting for US public hostname"
DNS_OK=0
for _ in $(seq 1 60); do
  if getent ahostsv4 "$HOST" >/dev/null 2>&1; then DNS_OK=1; break; fi
  DOH="$(curl -fsS --max-time 8 --resolve cloudflare-dns.com:443:1.1.1 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=${HOST}&type=A" 2>/dev/null || true)"
  A="$(echo "$DOH"|jq -r '.Answer[]?|select(.type==1)|.data' 2>/dev/null|head -n1||true)"
  if [ -n "$A" ]; then echo "$A $HOST" | sudo tee -a /etc/hosts >/dev/null; DNS_OK=1; break; fi
  sleep 2
done
[ "$DNS_OK" -eq 1 ] || { cat /tmp/cloudflared.log >&2; false; }
curl -fsS --retry 30 --retry-delay 2 --retry-all-errors "${URL}/sub.yaml" >/tmp/public-sub.yaml
grep -q 'GitHub临时美国VPN' /tmp/public-sub.yaml

STAGE="verify-public-path"; publish_state starting "$STAGE" "End-to-end verifying public VLESS path exits US"
cat >/tmp/client.json <<EOF
{"log":{"level":"info"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":2080}],"outbounds":[{"type":"vless","server":"${HOST}","server_port":443,"uuid":"${UUID}","tls":{"enabled":true,"server_name":"${HOST}"},"transport":{"type":"ws","path":"/ws","headers":{"Host":"${HOST}"}}}]}
EOF
nohup sing-box run -c /tmp/client.json >/tmp/sing-client.log 2>&1 & echo $! >/tmp/sing-client.pid
sleep 3
PUBLIC_IP=''; COUNTRY=''
for _ in $(seq 1 20); do
  PUBLIC_IP="$(curl -4fsS --max-time 20 --socks5-hostname 127.0.0.1:2080 https://api.ipify.org||true)"
  COUNTRY="$(curl -4fsS --max-time 20 --socks5-hostname 127.0.0.1:2080 https://ifconfig.co/country-iso||true)"; COUNTRY="$(echo "$COUNTRY"|tr -d '\r\n[:space:]'|tr '[:lower:]' '[:upper:]')"
  if [ "$COUNTRY" != US ]; then COUNTRY="$(curl -4fsS --max-time 20 --socks5-hostname 127.0.0.1:2080 https://ipapi.co/country/||true)"; COUNTRY="$(echo "$COUNTRY"|tr -d '\r\n[:space:]'|tr '[:lower:]' '[:upper:]')"; fi
  [ -n "$PUBLIC_IP" ]&&[ "$COUNTRY" = US ]&&break
  sleep 4
done
[ -n "$PUBLIC_IP" ] && [ "$COUNTRY" = US ] || { cat /tmp/sing-client.log >&2||true; false; }

STAGE="ready"
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; EXPIRES="$(date -u -d '+325 minutes' +%Y-%m-%dT%H:%M:%SZ)"
URL_FULL="${URL}/sub.yaml" EXIT_IP="$PUBLIC_IP" STARTED="$STARTED" EXPIRES="$EXPIRES" python3 - <<'PY'
import json,os
x={'ready':True,'status':'ready','stage':'ready','subscription_url':os.environ['URL_FULL'],'stable_subscription_path':'subscriptions/us-test.yaml','verified_country':'US','verified_exit_ip':os.environ['EXIT_IP'],'runner_direct_ip':open('/tmp/us-direct-ip').read().strip(),'started_at':os.environ['STARTED'],'approx_expires_at':os.environ['EXPIRES'],'run_id':os.environ.get('GITHUB_RUN_ID',''),'transport':'VLESS+WebSocket+TLS','upstream':'GitHub Actions runner direct egress'}
open('/tmp/us-state.json','w',encoding='utf-8').write(json.dumps(x,ensure_ascii=False,indent=2))
PY
put_repo_file "$SUB_PATH" /tmp/sub.yaml "Publish verified US VPN test subscription"
put_repo_file "$STATE_PATH" /tmp/us-state.json "Publish verified US VPN test state"
cat /tmp/us-state.json
trap - ERR
