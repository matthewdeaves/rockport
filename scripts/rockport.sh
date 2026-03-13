#!/bin/bash
set -euo pipefail

REGION="eu-west-2"
MASTER_KEY_SSM_PATH="/rockport/master-key"
TERRAFORM_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"
CONFIG_DIR="$(cd "$(dirname "$0")/../config" && pwd)"
CACHED_MASTER_KEY=""

# --- Helper functions ---

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
    --region "$REGION")
  echo "$CACHED_MASTER_KEY"
}

get_tunnel_url() {
  cd "$TERRAFORM_DIR"
  terraform output -raw tunnel_url 2>/dev/null
}

get_instance_id() {
  cd "$TERRAFORM_DIR"
  terraform output -raw instance_id 2>/dev/null
}

api_call() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local url
  url="$(get_tunnel_url)${path}"
  local key
  key="$(get_master_key)"

  if [[ -n "$data" ]]; then
    curl -s -X "$method" "$url" \
      -H "Authorization: Bearer $key" \
      -H "Content-Type: application/json" \
      -d "$data"
  else
    curl -s -X "$method" "$url" \
      -H "Authorization: Bearer $key"
  fi
}

# --- Subcommands ---

cmd_status() {
  local url
  url="$(get_tunnel_url)"
  echo "Checking health at $url..."
  local key
  key="$(get_master_key)"
  curl -s -H "Authorization: Bearer $key" "$url/health" | python3 -c "
import sys,json
d=json.load(sys.stdin)
h=[m.get('model','?') for m in d.get('healthy_endpoints',[])]
u=[m.get('model','?') for m in d.get('unhealthy_endpoints',[])]
print(f'Healthy ({len(h)}):')
for m in h: print(f'  ✓ {m}')
if u:
  print(f'Unhealthy ({len(u)}):')
  for m in u: print(f'  ✗ {m}')
" 2>/dev/null || echo "Could not reach health endpoint"
}

cmd_key_create() {
  local name="${1:?Usage: rockport key create <name>}"
  echo "Creating key '$name'..."
  api_call POST "/key/generate" "{\"key_name\": \"$name\"}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f\"Key:  {d.get('key','?')}\")
print(f\"Name: {d.get('key_name','?')}\")
print(f\"ID:   {d.get('token','?')}\")
"
}

cmd_key_list() {
  echo "Listing keys..."
  api_call GET "/key/list" | python3 -c "
import sys,json
data=json.load(sys.stdin)
keys=data if isinstance(data,list) else data.get('keys',data.get('data',[]))
if not keys:
  print('  No keys found')
  sys.exit()
for k in keys:
  name=k.get('key_name','unnamed')
  token=k.get('token','?')[:8]+'...'
  spend=k.get('spend',0) or 0
  print(f'  {name:<20} {token}  \${spend:.4f}')
"
}

cmd_key_info() {
  local key="${1:?Usage: rockport key info <key>}"
  api_call POST "/key/info" "{\"key\": \"$key\"}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
info=d.get('info',d)
print(f\"Name:      {info.get('key_name','?')}\")
print(f\"Token:     {info.get('token','?')}\")
print(f\"Spend:     \${info.get('spend',0) or 0:.4f}\")
print(f\"Max Budget:{' $'+str(info.get('max_budget')) if info.get('max_budget') else ' unlimited'}\")
print(f\"Created:   {info.get('created_at','?')}\")
print(f\"Expires:   {info.get('expires','never')}\")
"
}

cmd_key_revoke() {
  local key="${1:?Usage: rockport key revoke <key>}"
  echo "Revoking key..."
  api_call POST "/key/delete" "{\"keys\": [\"$key\"]}" | python3 -m json.tool
}

cmd_models() {
  echo "Listing models..."
  api_call GET "/v1/models" | python3 -c "
import sys,json
d=json.load(sys.stdin)
models=d.get('data',[])
for m in sorted(models, key=lambda x: x.get('id','')):
  print(f\"  {m.get('id','?')}\")
print(f'\n{len(models)} models available')
"
}

cmd_spend() {
  echo "Global spend..."
  api_call GET "/global/spend" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if isinstance(d, list):
  total=sum(r.get('spend',0) or 0 for r in d)
  print(f'Total spend: \${total:.4f}')
  for r in d:
    if r.get('api_key'):
      name=r.get('key_name','?')
      spend=r.get('spend',0) or 0
      print(f'  {name:<20} \${spend:.4f}')
else:
  spend=d.get('spend',0) or 0
  print(f'Total spend: \${spend:.4f}')
" 2>/dev/null || echo "Could not fetch spend data"
}

cmd_config_push() {
  local instance_id
  instance_id="$(get_instance_id)"
  echo "Pushing config to instance $instance_id..."

  # Base64-encode the config file for safe transport
  local config_b64
  config_b64=$(base64 -w0 "$CONFIG_DIR/litellm-config.yaml")

  aws ssm start-session \
    --target "$instance_id" \
    --region "$REGION" \
    --document-name AWS-StartInteractiveCommand \
    --parameters command="echo '$config_b64' | base64 -d | sudo tee /etc/litellm/config.yaml > /dev/null && sudo chown litellm:litellm /etc/litellm/config.yaml && sudo systemctl restart litellm && echo 'Config pushed and LiteLLM restarted'"
}

cmd_logs() {
  local instance_id
  instance_id="$(get_instance_id)"
  echo "Connecting to instance $instance_id..."
  aws ssm start-session \
    --target "$instance_id" \
    --region "$REGION" \
    --document-name AWS-StartInteractiveCommand \
    --parameters command="journalctl -u litellm -n 100 -f"
}

cmd_deploy() {
  echo "Deploying infrastructure..."
  cd "$TERRAFORM_DIR"
  terraform init -upgrade
  terraform apply
}

cmd_destroy() {
  echo "WARNING: This will destroy all Rockport infrastructure."
  read -rp "Type 'yes' to confirm: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 1
  fi
  cd "$TERRAFORM_DIR"
  terraform destroy
}

cmd_upgrade() {
  local instance_id
  instance_id="$(get_instance_id)"
  echo "Restarting LiteLLM on instance $instance_id..."
  aws ssm start-session \
    --target "$instance_id" \
    --region "$REGION" \
    --document-name AWS-StartInteractiveCommand \
    --parameters command="sudo systemctl restart litellm && echo 'LiteLLM restarted successfully'"
}

# --- Main ---

usage() {
  cat <<EOF
Usage: rockport <command> [args]

Commands:
  status              Check service health and model list
  models              List available models
  key create <name>   Create a new API key
  key list            List all API keys with spend
  key info <key>      Show key details and spend
  key revoke <key>    Revoke an API key
  spend               Show global spend summary
  config push         Push local config to instance and restart
  logs                Stream LiteLLM logs (via SSM)
  deploy              Run terraform apply
  destroy             Run terraform destroy (with confirmation)
  upgrade             Restart LiteLLM service
EOF
}

case "${1:-}" in
  status)   cmd_status ;;
  key)
    case "${2:-}" in
      create) cmd_key_create "${3:-}" ;;
      list)   cmd_key_list ;;
      info)   cmd_key_info "${3:-}" ;;
      revoke) cmd_key_revoke "${3:-}" ;;
      *)      usage; exit 1 ;;
    esac
    ;;
  models)   cmd_models ;;
  spend)    cmd_spend ;;
  config)
    case "${2:-}" in
      push) cmd_config_push ;;
      *)    usage; exit 1 ;;
    esac
    ;;
  logs)     cmd_logs ;;
  deploy)   cmd_deploy ;;
  destroy)  cmd_destroy ;;
  upgrade)  cmd_upgrade ;;
  *)        usage; exit 1 ;;
esac
