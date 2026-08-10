#!/usr/bin/env bash
set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?Missing AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Missing AWS_SECRET_ACCESS_KEY}"
: "${TAILSCALE_AUTH_KEY:?Missing TAILSCALE_AUTH_KEY}"
: "${TAILSCALE_API_KEY:?Missing TAILSCALE_API_KEY}"

INSTANCE_TYPE="${INSTANCE_TYPE:-t3.nano}"
PROJECT="qifu-global-exit"
ROLE_NAME="qifu-global-exit-node"
PROFILE_NAME="qifu-global-exit-node"
PARAM_NAME="/qifu/global-exit/tailscale-auth-key"

NODES=(
  "jp-tokyo|ap-northeast-1|qifu-jp-tokyo"
  "sg-singapore|ap-southeast-1|qifu-sg-singapore"
  "ae-uae|me-central-1|qifu-ae-uae"
  "za-cape-town|af-south-1|qifu-za-capetown"
  "br-sao-paulo|sa-east-1|qifu-br-saopaulo"
  "ch-zurich|eu-central-2|qifu-ch-zurich"
)

log(){ printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

ensure_region() {
  local region="$1"
  local status
  status="$(aws account get-region-opt-status --region-name "$region" --query RegionOptStatus --output text 2>/dev/null || true)"
  case "$status" in
    ENABLED|ENABLED_BY_DEFAULT|ENABLING) ;;
    DISABLED|DISABLING)
      log "Enabling AWS region $region"
      aws account enable-region --region-name "$region" >/dev/null
      ;;
    "") return 0 ;;
  esac

  if [[ "$status" == "ENABLING" || "$status" == "DISABLED" || "$status" == "DISABLING" ]]; then
    for _ in $(seq 1 60); do
      status="$(aws account get-region-opt-status --region-name "$region" --query RegionOptStatus --output text 2>/dev/null || true)"
      [[ "$status" == "ENABLED" || "$status" == "ENABLED_BY_DEFAULT" ]] && return 0
      sleep 30
    done
    echo "Region $region did not become enabled in time (status=$status)" >&2
    exit 1
  fi
}

ensure_iam() {
  local account_id trust policy
  account_id="$(aws sts get-caller-identity --query Account --output text)"
  trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

  if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    log "Creating EC2 IAM role"
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$trust" >/dev/null
  fi

  policy="$(jq -nc --arg account "$account_id" --arg param "$PARAM_NAME" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:["ssm:GetParameter"],Resource:("arn:aws:ssm:*:"+$account+":parameter"+$param)}]}')"
  aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name qifu-read-tailscale-key --policy-document "$policy"

  if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
    sleep 12
  fi
}

launch_region() {
  local label="$1" region="$2" hostname="$3"
  local vpc subnet sg ami existing user_data instance_id public_ip

  log "Preparing $label ($region)"
  ensure_region "$region"

  aws ssm put-parameter --region "$region" --name "$PARAM_NAME" --type SecureString --value "$TAILSCALE_AUTH_KEY" --overwrite >/dev/null

  vpc="$(aws ec2 describe-vpcs --region "$region" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
  if [[ -z "$vpc" || "$vpc" == "None" ]]; then
    vpc="$(aws ec2 create-default-vpc --region "$region" --query Vpc.VpcId --output text)"
  fi

  subnet="$(aws ec2 describe-subnets --region "$region" --filters Name=vpc-id,Values="$vpc" --query 'Subnets[0].SubnetId' --output text)"
  [[ -n "$subnet" && "$subnet" != "None" ]] || { echo "No subnet in $region" >&2; exit 1; }

  sg="$(aws ec2 describe-security-groups --region "$region" --filters Name=vpc-id,Values="$vpc" Name=group-name,Values="$PROJECT" --query 'SecurityGroups[0].GroupId' --output text)"
  if [[ -z "$sg" || "$sg" == "None" ]]; then
    sg="$(aws ec2 create-security-group --region "$region" --vpc-id "$vpc" --group-name "$PROJECT" --description 'Tailscale direct WireGuard UDP only' --query GroupId --output text)"
    aws ec2 authorize-security-group-ingress --region "$region" --group-id "$sg" --protocol udp --port 41641 --cidr 0.0.0.0/0 >/dev/null
  fi

  existing="$(aws ec2 describe-instances --region "$region" \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Name,Values=$hostname" "Name=instance-state-name,Values=pending,running,stopped,stopping" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)"

  if [[ -n "$existing" && "$existing" != "None" ]]; then
    instance_id="$existing"
    state="$(aws ec2 describe-instances --region "$region" --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].State.Name' --output text)"
    if [[ "$state" == "stopped" ]]; then aws ec2 start-instances --region "$region" --instance-ids "$instance_id" >/dev/null; fi
  else
    ami="$(aws ssm get-parameter --region "$region" --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)"
    user_data="$(mktemp)"
    cat >"$user_data" <<EOF
#!/bin/bash
set -euo pipefail
REGION='$region'
HOSTNAME='$hostname'
PARAM='$PARAM_NAME'

command -v aws >/dev/null 2>&1 || (dnf install -y awscli2 || dnf install -y awscli)
curl -fsSL https://tailscale.com/install.sh | sh
cat >/etc/sysctl.d/99-tailscale.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
sysctl --system >/dev/null
systemctl enable --now tailscaled

AUTH=''
for i in \$(seq 1 30); do
  AUTH="\$(aws ssm get-parameter --region "\$REGION" --name "\$PARAM" --with-decryption --query Parameter.Value --output text 2>/dev/null || true)"
  [[ -n "\$AUTH" && "\$AUTH" != "None" ]] && break
  sleep 5
done
[[ -n "\$AUTH" && "\$AUTH" != "None" ]]
tailscale up --auth-key="\$AUTH" --hostname="\$HOSTNAME" --advertise-exit-node
unset AUTH
EOF

    instance_id="$(aws ec2 run-instances --region "$region" --image-id "$ami" --instance-type "$INSTANCE_TYPE" \
      --subnet-id "$subnet" --security-group-ids "$sg" --associate-public-ip-address \
      --iam-instance-profile Name="$PROFILE_NAME" \
      --metadata-options HttpTokens=required,HttpEndpoint=enabled \
      --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=8,VolumeType=gp3,DeleteOnTermination=true}' \
      --user-data "file://$user_data" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$hostname},{Key=Project,Value=$PROJECT},{Key=Location,Value=$label}]" \
      --query 'Instances[0].InstanceId' --output text)"
    rm -f "$user_data"
  fi

  aws ec2 wait instance-running --region "$region" --instance-ids "$instance_id"
  public_ip="$(aws ec2 describe-instances --region "$region" --instance-ids "$instance_id" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  printf '%s|%s|%s|%s\n' "$label" "$region" "$hostname" "$public_ip" >> /tmp/qifu-nodes.txt
}

approve_exit_nodes() {
  log "Waiting for all six nodes to join Tailscale"
  local devices host id routes ok
  for entry in "${NODES[@]}"; do
    IFS='|' read -r _ _ host <<<"$entry"
    id=''
    for _ in $(seq 1 90); do
      devices="$(curl -fsS -u "$TAILSCALE_API_KEY:" 'https://api.tailscale.com/api/v2/tailnet/-/devices')"
      id="$(jq -r --arg h "$host" '.devices[] | select(((.hostname // "") == $h) or ((.name // "") | startswith($h + "."))) | .id' <<<"$devices" | head -n1)"
      [[ -n "$id" ]] && break
      sleep 10
    done
    [[ -n "$id" ]] || { echo "Tailscale node $host did not register" >&2; exit 1; }

    routes="$(curl -fsS -u "$TAILSCALE_API_KEY:" "https://api.tailscale.com/api/v2/device/$id/routes")"
    ok="$(jq -r '(.advertisedRoutes // []) | (index("0.0.0.0/0") != null)' <<<"$routes")"
    [[ "$ok" == "true" ]] || { echo "$host is not advertising exit-node routes" >&2; exit 1; }
    curl -fsS -u "$TAILSCALE_API_KEY:" -H 'Content-Type: application/json' \
      --data-binary "$(jq -c '{routes:.advertisedRoutes}' <<<"$routes")" \
      "https://api.tailscale.com/api/v2/device/$id/routes" >/dev/null
    echo "Approved exit node: $host"
  done
}

verify_end_to_end() {
  log "End-to-end verification through every exit node"
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
  sudo tailscale up --auth-key="$TAILSCALE_AUTH_KEY" --hostname=qifu-exit-verifier --accept-routes=false

  while IFS='|' read -r label region host expected_ip; do
    sudo tailscale set --exit-node="$host" --exit-node-allow-lan-access=false
    sleep 3
    actual_ip="$(curl -4 -fsS --max-time 20 https://checkip.amazonaws.com | tr -d '[:space:]')"
    if [[ "$actual_ip" != "$expected_ip" ]]; then
      echo "Verification failed for $host: expected $expected_ip, got $actual_ip" >&2
      exit 1
    fi
    printf 'PASS %-16s %-22s %s\n' "$label" "$host" "$actual_ip"
  done </tmp/qifu-nodes.txt

  sudo tailscale set --exit-node=
  sudo tailscale logout >/dev/null 2>&1 || true
}

cleanup_bootstrap_secret() {
  log "Removing bootstrap auth key copies from regional SSM"
  for entry in "${NODES[@]}"; do
    IFS='|' read -r _ region _ <<<"$entry"
    aws ssm delete-parameter --region "$region" --name "$PARAM_NAME" >/dev/null 2>&1 || true
  done
}

rm -f /tmp/qifu-nodes.txt
ensure_iam
for entry in "${NODES[@]}"; do
  IFS='|' read -r label region host <<<"$entry"
  launch_region "$label" "$region" "$host"
done
approve_exit_nodes
verify_end_to_end
cleanup_bootstrap_secret

log "All six exit nodes are live and verified"
cat /tmp/qifu-nodes.txt
