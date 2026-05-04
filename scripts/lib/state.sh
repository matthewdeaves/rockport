# shellcheck shell=bash
# scripts/lib/state.sh — Terraform state bucket + LiteLLM master-key (SSM)
# helpers. Sourced by rockport.sh. Relies on die(), get_region().

CACHED_MASTER_KEY=""

get_master_key() {
  if [[ -n "$CACHED_MASTER_KEY" ]]; then
    echo "$CACHED_MASTER_KEY"
    return
  fi
  CACHED_MASTER_KEY=$(aws ssm get-parameter \
    --name "$MASTER_KEY_SSM_PATH" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text \
    --region "$(get_region)") || {
    echo "ERROR: Failed to fetch master key from SSM. Is the infrastructure deployed?" >&2
    return 1
  }
  echo "$CACHED_MASTER_KEY"
}

ensure_master_key() {
  local region="$1"
  if aws ssm get-parameter --name "$MASTER_KEY_SSM_PATH" --region "$region" &>/dev/null 2>&1; then
    echo "  Master key ........... ok (exists in SSM)"
  else
    local master_key
    master_key="sk-$(openssl rand -hex 24)" || die "Failed to generate master key"
    aws ssm put-parameter \
      --name "$MASTER_KEY_SSM_PATH" \
      --value "$master_key" \
      --type SecureString \
      --region "$region" >/dev/null || die "Failed to store master key in SSM"
    echo "  Master key ........... created in SSM"
  fi
}

get_state_bucket() {
  local region
  region="$(get_region)"
  local account_id
  account_id=$(aws sts get-caller-identity --query Account --output text --region "$region") \
    || die "Failed to get AWS account ID"
  echo "rockport-tfstate-${account_id}-${region}"
}


ensure_state_backend() {
  local region bucket
  region="$(get_region)"
  bucket="$(get_state_bucket)"

  if aws s3api head-bucket --bucket "$bucket" --region "$region" >/dev/null 2>&1; then
    echo "  State bucket ......... ok ($bucket)"
  else
    aws s3api create-bucket \
      --bucket "$bucket" \
      --region "$region" \
      --create-bucket-configuration LocationConstraint="$region" >/dev/null || {
      echo "ERROR: Failed to create S3 state bucket '$bucket'" >&2
      return 1
    }

    aws s3api put-bucket-versioning \
      --bucket "$bucket" \
      --region "$region" \
      --versioning-configuration Status=Enabled \
      || die "Failed to enable bucket versioning on $bucket"

    aws s3api put-bucket-encryption \
      --bucket "$bucket" \
      --region "$region" \
      --server-side-encryption-configuration '{
        "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}, "BucketKeyEnabled": true}]
      }' || die "Failed to enable bucket encryption on $bucket"

    aws s3api put-public-access-block \
      --bucket "$bucket" \
      --region "$region" \
      --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
      || die "Failed to set public access block on $bucket"

    aws s3api put-bucket-policy \
      --bucket "$bucket" \
      --region "$region" \
      --policy "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{
          \"Sid\": \"DenyNonSSL\",
          \"Effect\": \"Deny\",
          \"Principal\": \"*\",
          \"Action\": \"s3:*\",
          \"Resource\": [
            \"arn:aws:s3:::$bucket\",
            \"arn:aws:s3:::$bucket/*\"
          ],
          \"Condition\": {
            \"Bool\": { \"aws:SecureTransport\": \"false\" }
          }
        }]
      }" || die "Failed to set bucket policy on $bucket"

    echo "  State bucket ......... created ($bucket)"
  fi
}

