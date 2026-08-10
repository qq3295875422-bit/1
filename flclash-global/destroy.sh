#!/usr/bin/env bash
set -euo pipefail
PROJECT_TAG="qifu-flclash-global"
REGIONS=(ap-northeast-1 ap-southeast-1 me-central-1 af-south-1 sa-east-1 eu-central-2)
for region in "${REGIONS[@]}"; do
  echo "[cleanup] $region"
  ids="$(aws ec2 describe-instances --region "$region" --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  if [[ -n "$ids" && "$ids" != "None" ]]; then
    aws ec2 terminate-instances --region "$region" --instance-ids $ids >/dev/null || true
    aws ec2 wait instance-terminated --region "$region" --instance-ids $ids || true
  fi

  vpc="$(aws ec2 describe-vpcs --region "$region" --filters "Name=tag:Project,Values=$PROJECT_TAG" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
  [[ -z "$vpc" || "$vpc" == "None" ]] && continue

  for sg in $(aws ec2 describe-security-groups --region "$region" --filters "Name=vpc-id,Values=$vpc" "Name=tag:Project,Values=$PROJECT_TAG" --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true); do
    aws ec2 delete-security-group --region "$region" --group-id "$sg" >/dev/null 2>&1 || true
  done
  for subnet in $(aws ec2 describe-subnets --region "$region" --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text 2>/dev/null || true); do
    aws ec2 delete-subnet --region "$region" --subnet-id "$subnet" >/dev/null 2>&1 || true
  done
  for igw in $(aws ec2 describe-internet-gateways --region "$region" --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null || true); do
    aws ec2 detach-internet-gateway --region "$region" --internet-gateway-id "$igw" --vpc-id "$vpc" >/dev/null 2>&1 || true
    aws ec2 delete-internet-gateway --region "$region" --internet-gateway-id "$igw" >/dev/null 2>&1 || true
  done
  aws ec2 delete-vpc --region "$region" --vpc-id "$vpc" >/dev/null 2>&1 || true
done
rm -rf flclash-global/.state qifu-global.yaml
echo "Cleanup finished."
