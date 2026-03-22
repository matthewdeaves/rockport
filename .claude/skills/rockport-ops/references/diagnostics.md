# Diagnostic Procedures

Layer-by-layer diagnostic commands for Rockport infrastructure. Use these in subagents to keep raw output out of the main context.

## Prerequisites

All commands use the deployer AWS profile unless noted otherwise.

```bash
# Set profile for all commands
export AWS_PROFILE=rockport
```

To get the instance ID and region:
```bash
REGION=$(grep '^region' /home/matt/rockport/terraform/terraform.tfvars | sed 's/.*= *"\(.*\)"/\1/')
INSTANCE_ID=$(cd /home/matt/rockport/terraform && terraform output -raw instance_id 2>/dev/null)
```

To get the tunnel URL and CF-Access credentials:
```bash
TUNNEL_URL=$(cd /home/matt/rockport/terraform && terraform output -raw tunnel_url 2>/dev/null)
CF_CLIENT_ID=$(cd /home/matt/rockport/terraform && terraform output -raw cf_access_client_id 2>/dev/null)
CF_CLIENT_SECRET=$(cd /home/matt/rockport/terraform && terraform output -raw cf_access_client_secret 2>/dev/null)
```

## Layer 1: Instance State

**Check if running:**
```bash
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=rockport" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Launch:LaunchTime}' \
  --output table --region "$REGION"
```

**Check if recently stopped by idle shutdown:**
```bash
# Check CloudWatch for recent idle-shutdown Lambda invocations
aws logs filter-log-events \
  --log-group-name /aws/lambda/rockport-idle-shutdown \
  --start-time $(($(date +%s) - 3600))000 \
  --query 'events[].message' --output text --region "$REGION" 2>/dev/null | tail -20
```

**Start a stopped instance:**
```bash
aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
# Wait for running state
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
```

## Layer 2: SSM Reachability

**Check SSM agent status:**
```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus,Agent:AgentVersion,Platform:PlatformName}' \
  --output table --region "$REGION"
```

If PingStatus is not "Online", the instance may be starting up (wait 2-3 minutes after start) or the SSM agent may be down.

## Layer 3: Service Health (via SSM)

Run commands on the instance via SSM. Use this pattern:

```bash
COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["systemctl status litellm cloudflared rockport-video postgresql --no-pager"]}' \
  --query 'Command.CommandId' --output text --region "$REGION")

# Wait and get output
sleep 3
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
  --output json --region "$REGION"
```

**Check individual service:**
```bash
# Replace SERVICE with: litellm, cloudflared, rockport-video, postgresql
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["systemctl status SERVICE --no-pager -l"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**Check memory pressure (t3.small has only 2GB):**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["free -h && echo --- && cat /proc/meminfo | grep -E \"MemTotal|MemAvailable|SwapTotal|SwapFree\""]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**Check disk space:**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["df -h / /var/lib/litellm"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

## Layer 4: Health Endpoints (via SSM)

```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["curl -s -o /dev/null -w \"%{http_code}\" http://localhost:4000/health && echo \" LiteLLM\" && curl -s -o /dev/null -w \"%{http_code}\" http://localhost:4001/health && echo \" Sidecar\""]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**Detailed health (LiteLLM):**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["curl -s http://localhost:4000/health | python3 -m json.tool"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**Detailed health (sidecar):**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["curl -s http://localhost:4001/health | python3 -m json.tool"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

## Layer 5: Recent Logs (via SSM)

**LiteLLM errors (last 10 minutes):**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["journalctl -u litellm --since \"10 min ago\" --no-pager -n 100 | grep -iE \"error|exception|traceback|fail|critical\" | tail -30"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**Sidecar errors:**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["journalctl -u rockport-video --since \"10 min ago\" --no-pager -n 100 | grep -iE \"error|exception|traceback|fail|critical\" | tail -30"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**Cloudflared errors:**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["journalctl -u cloudflared --since \"10 min ago\" --no-pager -n 50 | grep -iE \"error|ERR|fail\" | tail -20"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**PostgreSQL errors:**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["journalctl -u postgresql --since \"10 min ago\" --no-pager -n 50 | grep -iE \"error|fatal|panic\" | tail -20"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**Full recent logs (no filter, for context):**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["journalctl -u SERVICE --since \"5 min ago\" --no-pager -n 50"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

## Layer 6: External Reachability

**Test through Cloudflare Tunnel:**
```bash
# Health check (no auth needed for /health path in WAF)
curl -s -o /dev/null -w "%{http_code}" "https://${TUNNEL_URL}/health"

# Authenticated request (requires CF-Access headers)
curl -s -w "\n%{http_code}" \
  -H "CF-Access-Client-Id: ${CF_CLIENT_ID}" \
  -H "CF-Access-Client-Secret: ${CF_CLIENT_SECRET}" \
  "https://${TUNNEL_URL}/v1/models"
```

**Test with API key auth:**
```bash
MASTER_KEY=$(aws ssm get-parameter --name /rockport/master-key --with-decryption --query 'Parameter.Value' --output text --region "$REGION")

curl -s -w "\n%{http_code}" \
  -H "CF-Access-Client-Id: ${CF_CLIENT_ID}" \
  -H "CF-Access-Client-Secret: ${CF_CLIENT_SECRET}" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  "https://${TUNNEL_URL}/v1/models"
```

## Layer 7: Bedrock / IAM

**Check IAM role policies (via SSM):**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["aws sts get-caller-identity && echo --- && aws bedrock list-foundation-models --query \"modelSummaries[?contains(modelId, '\\''claude'\\'')].{Id:modelId,Status:modelLifecycle.status}\" --output table --region $REGION 2>&1 | head -20"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**Minimal test invocation (cheapest possible, ~$0.001):**
```bash
# Only use this if logs don't reveal the issue
MASTER_KEY=$(aws ssm get-parameter --name /rockport/master-key --with-decryption --query 'Parameter.Value' --output text --region "$REGION")

curl -s -w "\n%{http_code}" \
  -H "CF-Access-Client-Id: ${CF_CLIENT_ID}" \
  -H "CF-Access-Client-Secret: ${CF_CLIENT_SECRET}" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
  "https://${TUNNEL_URL}/v1/chat/completions"
```

## Layer 8: Idle Shutdown State

**Check CloudWatch alarm:**
```bash
aws cloudwatch describe-alarms \
  --alarm-names "rockport-idle-shutdown-errors" \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Updated:StateUpdatedTimestamp}' \
  --output table --region "$REGION"
```

**Check Lambda execution history:**
```bash
aws logs filter-log-events \
  --log-group-name /aws/lambda/rockport-idle-shutdown \
  --start-time $(($(date +%s) - 86400))000 \
  --query 'events[].message' --output text --region "$REGION" 2>/dev/null | tail -30
```

## Restarting Services (via SSM)

**Restart a single service:**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["sudo systemctl restart SERVICE && sleep 2 && systemctl is-active SERVICE"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

**Restart all Rockport services:**
```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["sudo systemctl restart litellm && sudo systemctl restart rockport-video && sleep 3 && systemctl is-active litellm && systemctl is-active rockport-video"]}' \
  --query 'Command.CommandId' --output text --region "$REGION"
```

## Using rockport.sh CLI

The CLI wraps many of these operations. For quick checks, prefer the CLI when it covers the need:

```bash
cd /home/matt/rockport
./scripts/rockport.sh status       # Health + model list
./scripts/rockport.sh logs         # Stream LiteLLM journal (interactive - avoid in subagents)
./scripts/rockport.sh spend today  # Today's spend
./scripts/rockport.sh monitor      # Key status + recent requests
./scripts/rockport.sh upgrade      # Restart services via SSM
./scripts/rockport.sh config push  # Push config changes + restart
```
