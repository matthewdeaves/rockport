# shellcheck shell=bash
# scripts/lib/ssm.sh — instance-side SSM helpers, deploy-artifact packaging,
# and the runtime-ops subcommands (config push / upgrade / logs / start /
# stop). Sourced by rockport.sh. Relies on die(), get_region(), load_env().

CACHED_INSTANCE_ID=""

get_artifacts_bucket() {
  local region account_id
  region="$(get_region)"
  account_id=$(aws sts get-caller-identity --query Account --output text --region "$region") \
    || die "Failed to get AWS account ID"
  echo "rockport-artifacts-${account_id}-${region}"
}

package_and_upload_artifact() {
  # Package sidecar/ + config/ into a tarball and upload to S3
  local region bucket
  region="$(get_region)"
  bucket="$(get_artifacts_bucket)"

  local tmpdir
  tmpdir=$(mktemp -d) || die "Failed to create temp directory"

  # Create artifact directory structure
  mkdir -p "$tmpdir/rockport-artifact/sidecar" || die "Failed to create artifact sidecar dir"
  mkdir -p "$tmpdir/rockport-artifact/config" || die "Failed to create artifact config dir"

  # Copy sidecar Python files
  cp "$SCRIPT_DIR/../sidecar/"*.py "$tmpdir/rockport-artifact/sidecar/" || die "Failed to copy sidecar files"

  # Copy config files (litellm config, systemd units)
  cp "$CONFIG_DIR/litellm-config.yaml" "$tmpdir/rockport-artifact/config/" || die "Failed to copy litellm-config.yaml"
  cp "$CONFIG_DIR/litellm.service" "$tmpdir/rockport-artifact/config/" || die "Failed to copy litellm.service"
  cp "$CONFIG_DIR/cloudflared.service" "$tmpdir/rockport-artifact/config/" || die "Failed to copy cloudflared.service"
  cp "$CONFIG_DIR/rockport-video.service" "$tmpdir/rockport-artifact/config/" || die "Failed to copy rockport-video.service"

  # Copy requirements lock file if present
  if [[ -f "$SCRIPT_DIR/../sidecar/requirements.lock" ]]; then
    cp "$SCRIPT_DIR/../sidecar/requirements.lock" "$tmpdir/rockport-artifact/sidecar/"
  fi

  # Create tarball
  tar czf "$tmpdir/rockport-artifact.tar.gz" -C "$tmpdir" rockport-artifact/ \
    || die "Failed to create artifact tarball"

  # Generate SHA256 checksum
  (cd "$tmpdir" && sha256sum rockport-artifact.tar.gz > rockport-artifact.tar.gz.sha256) \
    || die "Failed to generate artifact checksum"

  # Upload to S3
  echo "  Uploading artifact to s3://$bucket/deploy/rockport-artifact.tar.gz..."
  aws s3 cp "$tmpdir/rockport-artifact.tar.gz" \
    "s3://$bucket/deploy/rockport-artifact.tar.gz" \
    --region "$region" --quiet || {
    echo "ERROR: Failed to upload artifact to S3" >&2
    rm -rf "$tmpdir"
    return 1
  }
  aws s3 cp "$tmpdir/rockport-artifact.tar.gz.sha256" \
    "s3://$bucket/deploy/rockport-artifact.tar.gz.sha256" \
    --region "$region" --quiet
  echo "  Artifact uploaded (with checksum)."

  # Upload cloudflared binary to S3 as fallback for bootstrap
  # (GitHub CDN can return transient 404s during first boot)
  local cf_version cf_sha256
  cf_version=$(grep '^cloudflared_version' "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null | sed 's/.*= *"//;s/"//' || true)
  cf_sha256=$(grep '^cloudflared_sha256' "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null | sed 's/.*= *"//;s/"//' || true)
  # Fall back to variable defaults if not in tfvars
  if [[ -z "$cf_version" ]]; then
    cf_version=$(grep -A3 'variable "cloudflared_version"' "$TERRAFORM_DIR/variables.tf" | grep default | sed 's/.*= *"//;s/"//' || true)
  fi
  if [[ -z "$cf_sha256" ]]; then
    cf_sha256=$(grep -A3 'variable "cloudflared_sha256"' "$TERRAFORM_DIR/variables.tf" | grep default | sed 's/.*= *"//;s/"//' || true)
  fi
  if [[ -n "$cf_version" ]]; then
    echo "  Downloading cloudflared $cf_version for S3 fallback..."
    if curl -fsSL --retry 3 --retry-delay 5 \
      "https://github.com/cloudflare/cloudflared/releases/download/$cf_version/cloudflared-linux-amd64" \
      -o "$tmpdir/cloudflared-linux-amd64"; then
      # Verify checksum if available
      if [[ -n "$cf_sha256" ]]; then
        local actual_sha256 checksum_out
        checksum_out=$(sha256sum "$tmpdir/cloudflared-linux-amd64") || { echo "  WARNING: Failed to compute checksum"; rm -rf "$tmpdir"; return 0; }
        actual_sha256="${checksum_out%% *}"
        if [[ "$actual_sha256" != "$cf_sha256" ]]; then
          echo "  WARNING: cloudflared checksum mismatch, skipping S3 upload"
          rm -rf "$tmpdir"
          return 0
        fi
      fi
      aws s3 cp "$tmpdir/cloudflared-linux-amd64" \
        "s3://$bucket/deploy/cloudflared-linux-amd64" \
        --region "$region" --quiet
      echo "  cloudflared uploaded to S3 fallback."
    else
      echo "  WARNING: Could not download cloudflared for S3 fallback (GitHub may be unavailable)"
    fi
  fi

  rm -rf "$tmpdir"
}

get_instance_id() {
  if [[ -n "$CACHED_INSTANCE_ID" ]]; then
    echo "$CACHED_INSTANCE_ID"
    return
  fi
  CACHED_INSTANCE_ID=$(cd "$TERRAFORM_DIR" && terraform output -raw instance_id 2>&1) || {
    echo "ERROR: Failed to get instance_id from terraform. Run './scripts/rockport.sh deploy' first." >&2
    return 1
  }
  echo "$CACHED_INSTANCE_ID"
}

ssm_run() {
  local cmd_string="$1"
  local timeout="${2:-30}"
  local instance_id region cmd_id
  instance_id="$(get_instance_id)"
  region="$(get_region)"

  cmd_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\":[\"$cmd_string\"]}" \
    --timeout-seconds "$timeout" \
    --region "$region" \
    --query 'Command.CommandId' \
    --output text) || {
    echo "ERROR: Failed to send command via SSM" >&2
    return 1
  }

  # Poll for completion
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local status
    status=$(aws ssm get-command-invocation \
      --command-id "$cmd_id" \
      --instance-id "$instance_id" \
      --region "$region" \
      --query 'Status' \
      --output text 2>/dev/null) || true
    case "$status" in
      Success)
        aws ssm get-command-invocation \
          --command-id "$cmd_id" \
          --instance-id "$instance_id" \
          --region "$region" \
          --query 'StandardOutputContent' \
          --output text
        return 0
        ;;
      Failed|TimedOut|Cancelled)
        echo "ERROR: Command $status" >&2
        aws ssm get-command-invocation \
          --command-id "$cmd_id" \
          --instance-id "$instance_id" \
          --region "$region" \
          --query 'StandardErrorContent' \
          --output text >&2
        return 1
        ;;
    esac
    sleep 3
    elapsed=$((elapsed + 3))
  done
  echo "ERROR: Timed out waiting for command result" >&2
  return 1
}

wait_for_health() {
  local url="$1"
  local timeout="${2:-120}"
  local elapsed=0

  while [[ $elapsed -lt $timeout ]]; do
    local code
    local cf_h_args=()
    if [[ -n "$CACHED_CF_CLIENT_ID" && -n "$CACHED_CF_CLIENT_SECRET" ]]; then
      cf_h_args=(-H "CF-Access-Client-Id: $CACHED_CF_CLIENT_ID" -H "CF-Access-Client-Secret: $CACHED_CF_CLIENT_SECRET")
    fi
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url/health" "${cf_h_args[@]+"${cf_h_args[@]}"}" --max-time 5 2>/dev/null) || true
    # 200 = healthy, 401 = auth required but service is up — both mean ready
    if [[ "$code" == "200" || "$code" == "401" ]]; then
      echo "Services healthy. Rockport is ready."
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    printf "\r  Waiting for services... %ds" "$elapsed"
  done
  echo
  echo "WARNING: Health check did not respond within ${timeout}s."
  echo "Services may still be starting. Check with: rockport status"
  return 1
}

# --- Subcommands ---

cmd_config_push() {
  local instance_id region
  instance_id="$(get_instance_id)"
  region="$(get_region)"
  echo "Pushing config to instance $instance_id..."

  # Upload artifact to S3
  package_and_upload_artifact

  # Tell the instance to download and extract the artifact via SSM
  local artifacts_bucket
  artifacts_bucket="$(get_artifacts_bucket)"

  local params_file
  params_file=$(mktemp) || die "Failed to create temp file"
  trap 'rm -f "$params_file"' RETURN
  # Stop sidecar, download artifact, extract, restart services
  jq -n --arg bucket "$artifacts_bucket" --arg region "$region" \
    '{"commands":["systemctl stop rockport-video 2>/dev/null || true && aws s3 cp s3://\($bucket)/deploy/rockport-artifact.tar.gz /tmp/rockport-artifact.tar.gz --region \($region) && rm -rf /tmp/rockport-artifact && tar xzf /tmp/rockport-artifact.tar.gz -C /tmp && cp /tmp/rockport-artifact/config/litellm-config.yaml /etc/litellm/config.yaml && chown litellm:litellm /etc/litellm/config.yaml && cp /tmp/rockport-artifact/sidecar/*.py /opt/rockport-video/ && chown -R litellm:litellm /opt/rockport-video && cp /tmp/rockport-artifact/config/litellm.service /etc/systemd/system/litellm.service && cp /tmp/rockport-artifact/config/cloudflared.service /etc/systemd/system/cloudflared.service && cp /tmp/rockport-artifact/config/rockport-video.service /etc/systemd/system/rockport-video.service && systemctl daemon-reload && rm -rf /tmp/rockport-artifact /tmp/rockport-artifact.tar.gz && systemctl restart litellm && for i in $(seq 1 60); do curl -sf http://127.0.0.1:4000/health/readiness >/dev/null 2>&1 && break; sleep 2; done && systemctl start rockport-video && echo Config and sidecar pushed and services restarted"]}' \
    > "$params_file"

  local command_id
  command_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --region "$region" \
    --document-name "AWS-RunShellScript" \
    --parameters "file://$params_file" \
    --query "Command.CommandId" \
    --output text) || {
    echo "ERROR: Failed to send command via SSM" >&2
    return 1
  }

  echo "Waiting for restart..."
  if ! aws ssm wait command-executed \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --region "$region" 2>/dev/null; then
    echo "WARNING: Wait timed out or command may have failed" >&2
  fi

  local result
  result=$(aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --region "$region" \
    --query "StandardOutputContent" \
    --output text)
  echo "$result"
}

cmd_logs() {
  local instance_id
  instance_id="$(get_instance_id)"
  echo "Connecting to instance $instance_id..."
  aws ssm start-session \
    --target "$instance_id" \
    --region "$(get_region)" \
    --document-name AWS-StartInteractiveCommand \
    --parameters '{"command":["sudo journalctl -u litellm -n 100 -f"]}'
}

cmd_upgrade() {
  local instance_id
  instance_id="$(get_instance_id)"
  echo "Restarting LiteLLM on instance $instance_id..."
  local result
  result=$(ssm_run "sudo systemctl restart litellm && (sudo systemctl restart rockport-video 2>/dev/null || true) && echo Services restarted successfully" 30) \
    || die "Failed to restart services on instance $instance_id"
  echo "$result"
}

cmd_start() {
  local instance_id region
  instance_id="$(get_instance_id)"
  region="$(get_region)"

  local state
  state=$(aws ec2 describe-instances --instance-ids "$instance_id" --region "$region" \
    --query 'Reservations[0].Instances[0].State.Name' --output text) \
    || die "Failed to get instance state"

  if [[ "$state" == "running" ]]; then
    echo "Instance $instance_id is already running."
    wait_for_health "$(get_tunnel_url)" 30
    return
  fi

  echo "Starting instance $instance_id..."
  aws ec2 start-instances --instance-ids "$instance_id" --region "$region" > /dev/null \
    || die "Failed to start instance"
  echo "Waiting for running state..."
  aws ec2 wait instance-running --instance-ids "$instance_id" --region "$region" \
    || die "Timed out waiting for instance to start"
  echo "Instance running. Waiting for services..."

  wait_for_health "$(get_tunnel_url)" 120
}

cmd_stop() {
  local instance_id region
  instance_id="$(get_instance_id)"
  region="$(get_region)"

  local state
  state=$(aws ec2 describe-instances --instance-ids "$instance_id" --region "$region" \
    --query 'Reservations[0].Instances[0].State.Name' --output text) \
    || die "Failed to get instance state"

  if [[ "$state" == "stopped" ]]; then
    echo "Instance $instance_id is already stopped."
    return
  fi

  echo "Stopping instance $instance_id..."
  aws ec2 stop-instances --instance-ids "$instance_id" --region "$region" > /dev/null \
    || die "Failed to stop instance"
  echo "Waiting for stopped state..."
  aws ec2 wait instance-stopped --instance-ids "$instance_id" --region "$region" \
    || die "Timed out waiting for instance to stop"
  echo "Instance stopped."
}
