#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/qq3295875422-bit/1/main/flclash-global"
WORK="$HOME/qifu-flclash-global"
STATE_DIR="$WORK/.state"
OUT_CONFIG="$WORK/qifu-global.yaml"
DELIVERY_REGION="ap-northeast-1"
mkdir -p "$WORK" "$STATE_DIR"
chmod 700 "$WORK" "$STATE_DIR"

say() { printf '\n==> %s\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

command -v aws >/dev/null 2>&1 || fail "AWS CLI not found. Run this inside AWS CloudShell."
command -v curl >/dev/null 2>&1 || fail "curl not found"
command -v openssl >/dev/null 2>&1 || fail "openssl not found"

if ! command -v jq >/dev/null 2>&1; then
  say "Installing jq"
  if command -v dnf >/dev/null 2>&1; then sudo dnf -y install jq; elif command -v yum >/dev/null 2>&1; then sudo yum -y install jq; elif command -v apt-get >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y jq; else fail "jq unavailable"; fi
fi

say "Checking AWS console identity (no long-term access keys needed)"
IDENTITY_JSON="$(aws sts get-caller-identity --output json)" || fail "AWS identity unavailable"
ACCOUNT_ID="$(jq -r .Account <<<"$IDENTITY_JSON")"
ARN="$(jq -r .Arn <<<"$IDENTITY_JSON")"
echo "AWS account: $ACCOUNT_ID"
echo "Principal: $ARN"

say "Downloading deployment components"
for f in deploy.sh verify-and-generate.sh destroy.sh; do
  curl -fsSL "$REPO_RAW/$f" -o "$WORK/$f"
  chmod 700 "$WORK/$f"
done

# Install sing-box locally for end-to-end verification.
if ! command -v sing-box >/dev/null 2>&1; then
  say "Installing sing-box verifier in CloudShell"
  curl -fsSL https://sing-box.app/install.sh | sh
fi
command -v sing-box >/dev/null 2>&1 || fail "sing-box verifier installation failed"

say "Deploying six real regional Shadowsocks 2022 nodes"
export STATE_DIR OUT_CONFIG
cd "$HOME"
bash "$WORK/deploy.sh"

say "End-to-end verifying all six exit IPs and generating FlClash config"
bash "$WORK/verify-and-generate.sh"
chmod 600 "$OUT_CONFIG"
sha256sum "$OUT_CONFIG" | tee "$WORK/qifu-global.sha256"

say "Creating private S3 delivery object and 7-day presigned download URL"
SUFFIX="$(openssl rand -hex 4)"
BUCKET="qifu-flclash-${ACCOUNT_ID}-${SUFFIX}"
if aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$DELIVERY_REGION" \
  --create-bucket-configuration LocationConstraint="$DELIVERY_REGION" >/dev/null 2>&1; then
  aws s3api put-public-access-block --bucket "$BUCKET" --region "$DELIVERY_REGION" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null
  aws s3 cp "$OUT_CONFIG" "s3://$BUCKET/qifu-global.yaml" --region "$DELIVERY_REGION" \
    --sse AES256 --only-show-errors
  URL="$(aws s3 presign "s3://$BUCKET/qifu-global.yaml" --region "$DELIVERY_REGION" --expires-in 604800)"
  cat >"$WORK/delivery.json" <<EOF
{"bucket":"$BUCKET","region":"$DELIVERY_REGION","object":"qifu-global.yaml"}
EOF
  chmod 600 "$WORK/delivery.json"
  echo
  echo "============================================================"
  echo "QIFU_DEPLOYMENT_SUCCESS"
  echo "All six nodes passed real end-to-end egress-IP verification."
  echo "FlClash config download URL (valid up to 7 days):"
  echo "$URL"
  echo "Config file: $OUT_CONFIG"
  echo "Destroy command: bash $WORK/destroy-and-cleanup.sh"
  echo "============================================================"
else
  echo
  echo "WARNING: S3 delivery bucket could not be created (likely missing S3 permission)."
  echo "The verified FlClash config still exists here: $OUT_CONFIG"
  echo "Use CloudShell Actions -> Download file -> $OUT_CONFIG"
fi

cat >"$WORK/destroy-and-cleanup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
WORK="$HOME/qifu-flclash-global"
bash "$WORK/destroy.sh"
if [[ -f "$WORK/delivery.json" ]]; then
  BUCKET="$(jq -r .bucket "$WORK/delivery.json")"
  REGION="$(jq -r .region "$WORK/delivery.json")"
  aws s3 rm "s3://$BUCKET/qifu-global.yaml" --region "$REGION" >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1 || true
fi
echo "QIFU_DESTROY_SUCCESS"
EOF
chmod 700 "$WORK/destroy-and-cleanup.sh"
