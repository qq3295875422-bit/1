#!/usr/bin/env bash
set -euo pipefail

PROJECT_TAG="qifu-flclash-global"
SERVER_PORT="443"
CIPHER="2022-blake3-aes-128-gcm"
STATE_DIR="${STATE_DIR:-$PWD/flclash-global/.state}"
OUT_CONFIG="${OUT_CONFIG:-$PWD/qifu-global.yaml}"
mkdir -p "$STATE_DIR"

NODES=(
  "jp|ap-northeast-1|🇯🇵 东京|qifu-jp-tokyo"
  "sg|ap-southeast-1|🇸🇬 新加坡|qifu-sg-singapore"
  "ae|me-central-1|🇦🇪 阿联酋|qifu-ae-uae"
  "za|af-south-1|🇿🇦 南非|qifu-za-capetown"
  "br|sa-east-1|🇧🇷 巴西|qifu-br-saopaulo"
  "ch|eu-central-2|🇨🇭 瑞士|qifu-ch-zurich"
)

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }; }
need aws
need jq
need curl
need openssl

aws sts get-caller-identity >/dev/null

ensure_region_enabled() {
  local region="$1"
  local status
  status="$(aws account get-region-opt-status --region-name "$region" --query RegionOptStatus --output text 2>/dev/null || echo ENABLED_BY_DEFAULT)"
  case "$status" in
    ENABLED|ENABLED_BY_DEFAULT) return 0 ;;
    DISABLED)
      echo "[region] enabling $region"
      aws account enable-region --region-name "$region"
      ;;
    ENABLING) ;;
    *) echo "[region] status for $region: $status" ;;
  esac
  for _ in $(seq 1 120); do
    status="$(aws account get-region-opt-status --region-name "$region" --query RegionOptStatus --output text 2>/dev/null || true)"
    [[ "$status" == "ENABLED" || "$status" == "ENABLED_BY_DEFAULT" ]] && return 0
    sleep 10
  done
  echo "Timed out enabling region $region" >&2
  exit 1
}

ensure_network() {
  local region="$1"
  local vpc subnet igw rtb sg az

  vpc="$(aws ec2 describe-vpcs --region "$region" --filters "Name=tag:Project,Values=$PROJECT_TAG" --query 'Vpcs[0].VpcId' --output text)"
  if [[ -z "$vpc" || "$vpc" == "None" ]]; then
    vpc="$(aws ec2 create-vpc --region "$region" --cidr-block 10.250.0.0/16 --tag-specifications "ResourceType=vpc,Tags=[{Key=Project,Value=$PROJECT_TAG},{Key=Name,Value=qifu-flclash-vpc}]" --query 'Vpc.VpcId' --output text)"
    aws ec2 wait vpc-available --region "$region" --vpc-ids "$vpc"
    aws ec2 modify-vpc-attribute --region "$region" --vpc-id "$vpc" --enable-dns-support '{"Value":true}'
    aws ec2 modify-vpc-attribute --region "$region" --vpc-id "$vpc" --enable-dns-hostnames '{"Value":true}'
  fi

  igw="$(aws ec2 describe-internet-gateways --region "$region" --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[0].InternetGatewayId' --output text)"
  if [[ -z "$igw" || "$igw" == "None" ]]; then
    igw="$(aws ec2 create-internet-gateway --region "$region" --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Project,Value=$PROJECT_TAG}]" --query 'InternetGateway.InternetGatewayId' --output text)"
    aws ec2 attach-internet-gateway --region "$region" --internet-gateway-id "$igw" --vpc-id "$vpc"
  fi

  subnet="$(aws ec2 describe-subnets --region "$region" --filters "Name=vpc-id,Values=$vpc" "Name=tag:Project,Values=$PROJECT_TAG" --query 'Subnets[0].SubnetId' --output text)"
  if [[ -z "$subnet" || "$subnet" == "None" ]]; then
    az="$(aws ec2 describe-availability-zones --region "$region" --filters Name=state,Values=available --query 'AvailabilityZones[0].ZoneName' --output text)"
    subnet="$(aws ec2 create-subnet --region "$region" --vpc-id "$vpc" --cidr-block 10.250.1.0/24 --availability-zone "$az" --tag-specifications "ResourceType=subnet,Tags=[{Key=Project,Value=$PROJECT_TAG},{Key=Name,Value=qifu-flclash-public}]" --query 'Subnet.SubnetId' --output text)"
    aws ec2 modify-subnet-attribute --region "$region" --subnet-id "$subnet" --map-public-ip-on-launch
  fi

  rtb="$(aws ec2 describe-route-tables --region "$region" --filters "Name=vpc-id,Values=$vpc" "Name=association.main,Values=true" --query 'RouteTables[0].RouteTableId' --output text)"
  aws ec2 create-route --region "$region" --route-table-id "$rtb" --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw" >/dev/null 2>&1 || true

  sg="$(aws ec2 describe-security-groups --region "$region" --filters "Name=vpc-id,Values=$vpc" "Name=group-name,Values=qifu-flclash-ss" --query 'SecurityGroups[0].GroupId' --output text)"
  if [[ -z "$sg" || "$sg" == "None" ]]; then
    sg="$(aws ec2 create-security-group --region "$region" --vpc-id "$vpc" --group-name qifu-flclash-ss --description 'Qifu FlClash Shadowsocks 2022' --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJECT_TAG}]" --query GroupId --output text)"
  fi
  aws ec2 authorize-security-group-ingress --region "$region" --group-id "$sg" --ip-permissions \
    "IpProtocol=tcp,FromPort=$SERVER_PORT,ToPort=$SERVER_PORT,IpRanges=[{CidrIp=0.0.0.0/0,Description='Shadowsocks TCP'}]" >/dev/null 2>&1 || true
  aws ec2 authorize-security-group-ingress --region "$region" --group-id "$sg" --ip-permissions \
    "IpProtocol=udp,FromPort=$SERVER_PORT,ToPort=$SERVER_PORT,IpRanges=[{CidrIp=0.0.0.0/0,Description='Shadowsocks UDP'}]" >/dev/null 2>&1 || true

  printf '%s|%s|%s\n' "$vpc" "$subnet" "$sg"
}

pick_instance_type() {
  local region="$1" t offered
  for t in t3.nano t3.micro t3.small; do
    offered="$(aws ec2 describe-instance-type-offerings --region "$region" --location-type region --filters "Name=instance-type,Values=$t" --query 'InstanceTypeOfferings[0].InstanceType' --output text 2>/dev/null || true)"
    if [[ "$offered" == "$t" ]]; then printf '%s\n' "$t"; return 0; fi
  done
  echo "No supported t3 instance type in $region" >&2
  exit 1
}

launch_node() {
  local code="$1" region="$2" label="$3" hostname="$4"
  local network vpc subnet sg ami itype pass userdata instance ip

  ensure_region_enabled "$region"
  network="$(ensure_network "$region")"
  IFS='|' read -r vpc subnet sg <<<"$network"
  ami="$(aws ssm get-parameter --region "$region" --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query 'Parameter.Value' --output text)"
  itype="$(pick_instance_type "$region")"

  instance="$(aws ec2 describe-instances --region "$region" \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=tag:Node,Values=$hostname" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)"

  if [[ -n "$instance" && "$instance" != "None" ]]; then
    echo "Existing node found for $label ($instance); terminating so credentials are regenerated." >&2
    aws ec2 terminate-instances --region "$region" --instance-ids "$instance" >/dev/null
    aws ec2 wait instance-terminated --region "$region" --instance-ids "$instance"
  fi

  pass="$(openssl rand -base64 16 | tr -d '\n')"
  userdata="$STATE_DIR/userdata-$code.sh"
  cat >"$userdata" <<EOF
#!/usr/bin/env bash
set -euo pipefail
hostnamectl set-hostname '$hostname'
dnf -y install curl ca-certificates
curl -fsSL https://sing-box.app/install.sh | sh
install -d -m 0755 /etc/sing-box
cat >/etc/sing-box/config.json <<'JSON'
{
  "log": {"level": "warn", "timestamp": true},
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": $SERVER_PORT,
      "method": "$CIPHER",
      "password": "$pass"
    }
  ],
  "outbounds": [
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"final": "direct"}
}
JSON
sing-box check -c /etc/sing-box/config.json
systemctl enable sing-box
systemctl restart sing-box
EOF
  chmod 600 "$userdata"

  instance="$(aws ec2 run-instances --region "$region" --image-id "$ami" --instance-type "$itype" \
    --subnet-id "$subnet" --security-group-ids "$sg" --associate-public-ip-address \
    --user-data "file://$userdata" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=$PROJECT_TAG},{Key=Node,Value=$hostname},{Key=Name,Value=$hostname}]" \
    --query 'Instances[0].InstanceId' --output text)"

  aws ec2 wait instance-running --region "$region" --instance-ids "$instance"
  ip="$(aws ec2 describe-instances --region "$region" --instance-ids "$instance" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

  jq -n --arg code "$code" --arg region "$region" --arg label "$label" --arg hostname "$hostname" \
    --arg instance "$instance" --arg ip "$ip" --arg pass "$pass" --arg cipher "$CIPHER" --argjson port "$SERVER_PORT" \
    '{code:$code,region:$region,label:$label,hostname:$hostname,instance_id:$instance,ip:$ip,password:$pass,cipher:$cipher,port:$port}' \
    >"$STATE_DIR/$code.json"

  rm -f "$userdata"
  echo "[launched] $label $region $instance $ip $itype"
}

for spec in "${NODES[@]}"; do
  IFS='|' read -r code region label hostname <<<"$spec"
  launch_node "$code" "$region" "$label" "$hostname"
done

jq -s '.' "$STATE_DIR"/{jp,sg,ae,za,br,ch}.json >"$STATE_DIR/nodes.json"

echo "Deployment complete. Node state: $STATE_DIR/nodes.json"
