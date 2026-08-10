#!/usr/bin/env bash
set -euo pipefail
: "${AWS_ACCESS_KEY_ID:?Missing AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Missing AWS_SECRET_ACCESS_KEY}"

PROJECT="qifu-global-exit"
REGIONS=(ap-northeast-1 ap-southeast-1 me-central-1 af-south-1 sa-east-1 eu-central-2)

for region in "${REGIONS[@]}"; do
  echo "Cleaning $region"
  ids="$(aws ec2 describe-instances --region "$region" --filters "Name=tag:Project,Values=$PROJECT" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  if [[ -n "$ids" && "$ids" != "None" ]]; then
    aws ec2 terminate-instances --region "$region" --instance-ids $ids >/dev/null
    aws ec2 wait instance-terminated --region "$region" --instance-ids $ids || true
  fi
  aws ssm delete-parameter --region "$region" --name /qifu/global-exit/tailscale-auth-key >/dev/null 2>&1 || true

  vpc="$(aws ec2 describe-vpcs --region "$region" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
  if [[ -n "$vpc" && "$vpc" != "None" ]]; then
    sg="$(aws ec2 describe-security-groups --region "$region" --filters Name=vpc-id,Values="$vpc" Name=group-name,Values="$PROJECT" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
    if [[ -n "$sg" && "$sg" != "None" ]]; then aws ec2 delete-security-group --region "$region" --group-id "$sg" >/dev/null 2>&1 || true; fi
  fi
done

echo "EC2 exit nodes removed. Tailscale machine records can be removed from the Tailscale Machines page if desired."
