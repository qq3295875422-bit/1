#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${STATE_DIR:-$PWD/flclash-global/.state}"
OUT_CONFIG="${OUT_CONFIG:-$PWD/qifu-global.yaml}"
NODES_JSON="$STATE_DIR/nodes.json"
TEST_PORT=10990

[[ -f "$NODES_JSON" ]] || { echo "Missing $NODES_JSON" >&2; exit 1; }
command -v sing-box >/dev/null 2>&1 || { echo "sing-box is required on the verifier" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || exit 1
command -v curl >/dev/null 2>&1 || exit 1

verify_one() {
  local idx="$1"
  local label ip port cipher pass cfg pid got ok=0
  label="$(jq -r ".[$idx].label" "$NODES_JSON")"
  ip="$(jq -r ".[$idx].ip" "$NODES_JSON")"
  port="$(jq -r ".[$idx].port" "$NODES_JSON")"
  cipher="$(jq -r ".[$idx].cipher" "$NODES_JSON")"
  pass="$(jq -r ".[$idx].password" "$NODES_JSON")"
  cfg="$STATE_DIR/verify-$idx.json"

  cat >"$cfg" <<EOF
{
  "log": {"level": "error"},
  "inbounds": [
    {"type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": $TEST_PORT}
  ],
  "outbounds": [
    {"type": "shadowsocks", "tag": "ss-out", "server": "$ip", "server_port": $port, "method": "$cipher", "password": "$pass"}
  ],
  "route": {"final": "ss-out"}
}
EOF

  sing-box check -c "$cfg" >/dev/null
  for attempt in $(seq 1 40); do
    sing-box run -c "$cfg" >"$STATE_DIR/verify-$idx.log" 2>&1 &
    pid=$!
    sleep 1
    got="$(curl -4 -fsS --max-time 12 --proxy "socks5h://127.0.0.1:$TEST_PORT" https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
    if [[ "$got" == "$ip" ]]; then
      echo "PASS | $label | expected=$ip | observed=$got"
      ok=1
      break
    fi
    echo "WAIT | $label | attempt=$attempt | observed=${got:-none}" >&2
    sleep 5
  done
  [[ "$ok" == "1" ]] || { echo "FAIL | $label | expected=$ip" >&2; return 1; }
}

for idx in 0 1 2 3 4 5; do
  verify_one "$idx"
done

cat >"$OUT_CONFIG" <<'EOF'
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true
profile:
  store-selected: true
  store-fake-ip: true
proxies:
EOF

for idx in 0 1 2 3 4 5; do
  label="$(jq -r ".[$idx].label" "$NODES_JSON")"
  ip="$(jq -r ".[$idx].ip" "$NODES_JSON")"
  port="$(jq -r ".[$idx].port" "$NODES_JSON")"
  cipher="$(jq -r ".[$idx].cipher" "$NODES_JSON")"
  pass="$(jq -r ".[$idx].password" "$NODES_JSON")"
  cat >>"$OUT_CONFIG" <<EOF
  - name: "$label"
    type: ss
    server: $ip
    port: $port
    cipher: $cipher
    password: "$pass"
    udp: true
    ip-version: ipv4
EOF
done

cat >>"$OUT_CONFIG" <<'EOF'
proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "♻️ 自动选择"
      - "🇯🇵 东京"
      - "🇸🇬 新加坡"
      - "🇦🇪 阿联酋"
      - "🇿🇦 南非"
      - "🇧🇷 巴西"
      - "🇨🇭 瑞士"
      - DIRECT
  - name: "♻️ 自动选择"
    type: url-test
    proxies:
      - "🇯🇵 东京"
      - "🇸🇬 新加坡"
      - "🇦🇪 阿联酋"
      - "🇿🇦 南非"
      - "🇧🇷 巴西"
      - "🇨🇭 瑞士"
    url: "https://www.gstatic.com/generate_204"
    interval: 300
    tolerance: 80
rules:
  - MATCH,🚀 节点选择
EOF

chmod 600 "$OUT_CONFIG"
echo "All six nodes passed end-to-end public-IP verification."
echo "Generated FlClash/Mihomo config: $OUT_CONFIG"
