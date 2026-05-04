# shellcheck shell=bash
# scripts/lib/spend.sh — spend reporting (LiteLLM /spend/logs + AWS Cost
# Explorer) and the live-monitor subcommand. Sourced by rockport.sh.
# Relies on die(), api_call(), get_region().

cmd_spend() {
  local subcmd="${1:-}"

  case "$subcmd" in
    keys)
      local response
      response=$(api_call GET "/key/list?return_full_object=true")

      echo "$response" | jq -r '
        (.keys // .) | map(select(type == "object")) |
        if length == 0 then "  No keys found."
        else
          "Spend by Key (current budget period)",
          "─────────────────────────────────────────────────────────────────",
          "  Key                       Spend       Budget       Created",
          "  ─────────────────────────────────────────────────────────────",
          (sort_by(.spend // 0) | reverse | . as $keys |
            ($keys[] |
              (.key_alias // .key_name // "unnamed") as $name |
              ($name | if length > 24 then .[0:24] else . + (" " * ([24 - length, 0] | max)) end) as $pad_name |
              ("$\(.spend // 0 | . * 10000 | round / 10000)" |
                if length > 10 then .[0:10] else . + (" " * ([10 - length, 0] | max)) end) as $pad_spend |
              (if .max_budget then "$\(.max_budget)/day" else "unlimited" end |
                if length > 11 then .[0:11] else . + (" " * ([11 - length, 0] | max)) end) as $pad_budget |
              (.created_at // "" | split("T")[0]) as $created |
              "  \($pad_name)  \($pad_spend)  \($pad_budget)  \($created)"
            ),
            "",
            "  Total:                      $\($keys | map(.spend // 0) | add | . * 10000 | round / 10000)"
          )
        end'
      ;;
    models)
      echo "Fetching spend logs..."
      local logs
      logs=$(api_call GET "/spend/logs?start_date=2020-01-01")

      echo "$logs" | jq -r '
        map(select(.model_group != null and .model_group != "")) |
        [group_by(.model_group)[] |
          {model: .[0].model_group,
           spend: (map(.spend // 0) | add),
           requests: length,
           tokens: (map(.total_tokens // 0) | add)}] |
        sort_by(.spend) | reverse |
        if length == 0 then "  No model spend recorded."
        else
          "Spend by Model (all time)",
          "─────────────────────────────────────────────────────────────────",
          "  Model                     Spend       Requests     Tokens",
          "  ─────────────────────────────────────────────────────────────",
          (.[] |
            (.model | if length > 28 then .[0:28] else . + (" " * ([28 - length, 0] | max)) end) as $pad_model |
            ("$\(.spend | . * 10000 | round / 10000)" |
              if length > 10 then .[0:10] else . + (" " * ([10 - length, 0] | max)) end) as $pad_spend |
            (.requests | tostring |
              if length > 11 then .[0:11] else . + (" " * ([11 - length, 0] | max)) end) as $pad_req |
            (if .tokens > 0 then (.tokens | tostring) else "-" end) as $tokens |
            "  \($pad_model)  \($pad_spend)  \($pad_req)  \($tokens)"
          ),
          "",
          "  Total:                      $\(map(.spend) | add | . * 10000 | round / 10000)"
        end'
      ;;
    daily)
      echo "Fetching spend logs..."
      local logs days
      days="${2:-30}"
      local start_date
      start_date=$(date -u -d "$days days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"${days}"d +%Y-%m-%d)
      logs=$(api_call GET "/spend/logs?start_date=$start_date")

      echo "$logs" | jq -r --arg days "$days" '
        map(select(.model_group != null and .model_group != "")) |
        [group_by(.startTime[:10])[] |
          {date: .[0].startTime[:10],
           spend: (map(.spend // 0) | add),
           requests: length,
           tokens: (map(.total_tokens // 0) | add)}] |
        sort_by(.date) | reverse |
        if length == 0 then "  No spend recorded in the last \($days) days."
        else
          "Daily Spend (last \($days) days)",
          "─────────────────────────────────────────────────────────────────",
          "  Date           Spend       Requests     Tokens",
          "  ─────────────────────────────────────────────────────────────",
          (.[] |
            (.date | . + (" " * ([13 - length, 0] | max))) as $pad_date |
            ("$\(.spend | . * 10000 | round / 10000)" |
              if length > 10 then .[0:10] else . + (" " * ([10 - length, 0] | max)) end) as $pad_spend |
            (.requests | tostring |
              if length > 11 then .[0:11] else . + (" " * ([11 - length, 0] | max)) end) as $pad_req |
            (if .tokens > 0 then (.tokens | tostring) else "-" end) as $tokens |
            "  \($pad_date)  \($pad_spend)  \($pad_req)  \($tokens)"
          ),
          "",
          "  Total:           $\(map(.spend) | add | . * 10000 | round / 10000)"
        end'
      ;;
    today)
      echo "Fetching today's spend..."
      local today
      today=$(date -u +%Y-%m-%d)
      local logs
      logs=$(api_call GET "/spend/logs?start_date=$today")

      echo "$logs" | jq -r '
        map(select(.model_group != null and .model_group != "")) |
        if length == 0 then "\nNo spend recorded today."
        else
          [group_by(.metadata.user_api_key_alias // "unknown")[] |
            {key: (.[0].metadata.user_api_key_alias // "unknown"),
             items: [group_by(.model_group)[] |
               {model: .[0].model_group,
                spend: (map(.spend // 0) | add),
                requests: length,
                tokens: (map(.total_tokens // 0) | add)}] | sort_by(.spend) | reverse,
             total_spend: (map(.spend // 0) | add),
             total_requests: length}] |
          sort_by(.total_spend) | reverse |
          "\nToday'\''s Spend (\(map(.total_requests) | add) requests, $\(map(.total_spend) | add | . * 10000 | round / 10000) total)",
          "─────────────────────────────────────────────────────────────────",
          (.[] |
            "\n  \(.key)  (\(.total_requests) requests, $\(.total_spend | . * 10000 | round / 10000))",
            (.items[] |
              "    \(.model | if length > 22 then .[0:22] else . + (" " * ([22 - length, 0] | max)) end)  $\(.spend | . * 10000 | round / 10000 | tostring | if length > 8 then .[0:8] else . end)  \(.requests) req" +
              (if .tokens > 0 then "  \(.tokens) tok" else "" end)
            )
          )
        end'
      ;;
    infra)
      # AWS costs from Cost Explorer (gross + credits)
      local months="${2:-3}"
      local start_date end_date
      start_date=$(date -u -d "$months months ago" +%Y-%m-01 2>/dev/null || date -u -v-"${months}"m +%Y-%m-01)
      end_date=$(date -u +%Y-%m-%d)

      echo "Fetching AWS costs (last $months months)..."
      # Gross costs by service (excluding credit records)
      local ce_gross
      ce_gross=$(env -u AWS_PROFILE aws ce get-cost-and-usage \
        --time-period "Start=$start_date,End=$end_date" \
        --granularity MONTHLY \
        --metrics UnblendedCost \
        --group-by Type=DIMENSION,Key=SERVICE \
        --filter '{"Not":{"Dimensions":{"Key":"RECORD_TYPE","Values":["Credit"]}}}' \
        --region us-east-1 \
        --output json 2>&1) || {
        if echo "$ce_gross" | grep -q "AccessDeniedException"; then
          echo "ERROR: Missing ce:GetCostAndUsage permission."
          echo "Update the RockportAdmin IAM policy (see terraform/rockport-admin-policy.json)"
          echo "and re-apply it in the AWS console."
        else
          echo "ERROR: $ce_gross"
        fi
        return 1
      }
      # Credits/usage by record type
      local ce_totals
      ce_totals=$(env -u AWS_PROFILE aws ce get-cost-and-usage \
        --time-period "Start=$start_date,End=$end_date" \
        --granularity MONTHLY \
        --metrics UnblendedCost \
        --group-by Type=DIMENSION,Key=RECORD_TYPE \
        --region us-east-1 \
        --output json 2>/dev/null) || true

      echo "$ce_gross" | jq -r '
        .ResultsByTime | reverse |
        if length == 0 then "  No cost data found."
        else
          "AWS Costs (gross, before credits)",
          "─────────────────────────────────────────────────────────────────",
          (.[] |
            .TimePeriod.Start[:7] as $month |
            [.Groups[] |
              {service: .Keys[0],
               cost: (.Metrics.UnblendedCost.Amount | tonumber)}] |
            sort_by(.cost) | reverse |
            map(select(.cost > 0.005)) |
            if length == 0 then
              "\n  \($month):  $0.00"
            else
              "\n  \($month):" as $header |
              ($header,
              (.[] |
                (.service |
                gsub(" \\(Amazon Bedrock Edition\\)"; "") |
                gsub("Amazon Elastic Compute Cloud - Compute"; "EC2 Compute") |
                gsub("Amazon Simple Storage Service"; "S3") |
                gsub("Amazon Virtual Private Cloud"; "VPC") |
                gsub("AWS Key Management Service"; "KMS") |
                gsub("Amazon Simple Notification Service"; "SNS") |
                gsub("Amazon Simple Queue Service"; "SQS") |
                if length > 42 then .[0:42] else . + (" " * ([42 - length, 0] | max)) end) as $pad_svc |
                "    \($pad_svc)  $\(.cost | . * 100 | round / 100)"
              ),
              "    ──────────────────────────────────────────────────",
              "    Total                                               $\(map(.cost) | add | . * 100 | round / 100)")
            end
          ),
          ""
        end'

      # Show credit summary
      if [[ -n "${ce_totals:-}" ]]; then
        echo "$ce_totals" | jq -r '
          [.ResultsByTime[].Groups[] | {type: .Keys[0], cost: (.Metrics.UnblendedCost.Amount | tonumber)}] |
          (map(select(.type == "Usage")) | map(.cost) | add // 0) as $gross |
          (map(select(.type == "Credit")) | map(.cost) | add // 0) as $credits |
          if $credits < 0 then
            "Account Totals (all months shown)",
            "─────────────────────────────────────────────────────────────────",
            "  Gross usage:    $\($gross | . * 100 | round / 100)",
            "  Credits:       -$\($credits | fabs | . * 100 | round / 100)",
            "  Net cost:       $\($gross + $credits | . * 100 | round / 100)",
            ""
          else empty end'
      fi
      ;;
    *)
      # Default: combined summary
      echo "Rockport Spend Summary"
      echo "═══════════════════════════════════════════════════════════════════"
      echo

      # --- AWS costs (Cost Explorer) — gross usage + credits ---
      local infra_available=true ce_end
      ce_end=$(date -u +%Y-%m-%d)
      local ce_start
      ce_start=$(date -u -d "3 months ago" +%Y-%m-01 2>/dev/null || date -u -v-3m +%Y-%m-01)
      # CE needs admin credentials — the rockport profile is the deployer which may
      # lack ce:GetCostAndUsage. Unset AWS_PROFILE so it falls back to default creds.
      # Gross costs by service (excluding credit records)
      local ce_gross
      ce_gross=$(env -u AWS_PROFILE aws ce get-cost-and-usage \
        --time-period "Start=$ce_start,End=$ce_end" \
        --granularity MONTHLY \
        --metrics UnblendedCost \
        --group-by Type=DIMENSION,Key=SERVICE \
        --filter '{"Not":{"Dimensions":{"Key":"RECORD_TYPE","Values":["Credit"]}}}' \
        --region us-east-1 \
        --output json 2>/dev/null) || infra_available=false
      # Credits/usage totals by record type
      local ce_totals
      if [[ "$infra_available" == "true" ]]; then
        ce_totals=$(env -u AWS_PROFILE aws ce get-cost-and-usage \
          --time-period "Start=$ce_start,End=$ce_end" \
          --granularity MONTHLY \
          --metrics UnblendedCost \
          --group-by Type=DIMENSION,Key=RECORD_TYPE \
          --region us-east-1 \
          --output json 2>/dev/null) || infra_available=false
      fi

      # --- Model usage costs (LiteLLM) ---
      local global
      global=$(api_call GET "/global/spend") || { echo "Could not fetch spend data."; return 1; }
      local model_spend
      model_spend=$(echo "$global" | jq -r 'if type == "array" then (map(.spend // 0) | add) else (.spend // 0) end | . * 10000 | round / 10000')

      # --- Totals ---
      if [[ "$infra_available" == "true" ]]; then
        echo "$ce_totals" | jq -r --arg model_spend "$model_spend" '
          [.ResultsByTime[].Groups[] | {type: .Keys[0], cost: (.Metrics.UnblendedCost.Amount | tonumber)}] |
          (map(select(.type == "Usage")) | map(.cost) | add // 0) as $gross |
          (map(select(.type == "Credit")) | map(.cost) | add // 0) as $credits |
          ($gross + $credits) as $net |
          "  AWS account total (gross):  $\($gross | . * 100 | round / 100)",
          (if $credits < 0 then
            "  Credits applied:           -$\($credits | fabs | . * 100 | round / 100)"
          else empty end),
          "  AWS account total (net):    $\($net | . * 100 | round / 100)",
          "",
          "  LiteLLM model usage:        $\($model_spend)"'
      else
        echo "  LiteLLM model usage:  \$$model_spend  (Bedrock inference)"
        echo "  AWS costs: (add ce:GetCostAndUsage to admin policy — see 'spend infra')"
      fi
      echo

      # --- AWS breakdown (current month, gross costs by service) ---
      if [[ "$infra_available" == "true" ]]; then
        echo "$ce_gross" | jq -r '
          .ResultsByTime | last |
          .TimePeriod.Start[:7] as $month |
          [.Groups[] |
            {service: .Keys[0],
             cost: (.Metrics.UnblendedCost.Amount | tonumber)}] |
          sort_by(.cost) | reverse |
          map(select(.cost > 0.005)) |
          if length == 0 then empty
          else
            "  AWS Breakdown (\($month), gross):",
            "  ───────────────────────────────────────────────────────────────",
            (.[] |
              (.service |
                gsub(" \\(Amazon Bedrock Edition\\)"; "") |
                gsub("Amazon Elastic Compute Cloud - Compute"; "EC2 Compute") |
                gsub("Amazon Simple Storage Service"; "S3") |
                gsub("Amazon Virtual Private Cloud"; "VPC") |
                gsub("AWS Key Management Service"; "KMS") |
                gsub("Amazon Simple Notification Service"; "SNS") |
                gsub("Amazon Simple Queue Service"; "SQS") |
                if length > 38 then .[0:38] else . + (" " * ([38 - length, 0] | max)) end) as $pad_svc |
              "    \($pad_svc)  $\(.cost | . * 100 | round / 100)"
            ),
            ""
          end'
      fi

      # --- Model breakdown ---
      local logs keys
      logs=$(api_call GET "/spend/logs?start_date=2020-01-01")
      keys=$(api_call GET "/key/list?return_full_object=true" 2>/dev/null) || true

      echo "$logs" | jq -r '
        map(select(.model_group != null and .model_group != "")) |
        [group_by(.model_group)[] |
          {model: .[0].model_group,
           spend: (map(.spend // 0) | add),
           requests: length}] |
        sort_by(.spend) | reverse |
        if length == 0 then empty
        else
          "  Model Usage (all time):",
          "  ───────────────────────────────────────────────────────────────",
          (.[] |
            (.model | if length > 28 then .[0:28] else . + (" " * ([28 - length, 0] | max)) end) as $pad_model |
            ("$\(.spend | . * 10000 | round / 10000)" |
              if length > 10 then .[0:10] else . + (" " * ([10 - length, 0] | max)) end) as $pad_spend |
            "    \($pad_model)  \($pad_spend)  \(.requests) requests"
          ),
          ""
        end'

      # By key
      if [[ -n "$keys" ]]; then
        echo "$keys" | jq -r '
          (.keys // .) | map(select(type == "object")) |
          if length == 0 then empty
          else
            "  By Key:",
            "  ───────────────────────────────────────────────────────────────",
            (sort_by(.spend // 0) | reverse | .[] |
              (.key_alias // .key_name // "unnamed") as $name |
              ($name | if length > 26 then .[0:26] else . + (" " * ([26 - length, 0] | max)) end) as $padded |
              ("$\(.spend // 0 | . * 10000 | round / 10000)" |
                if length > 10 then .[0:10] else . + (" " * ([10 - length, 0] | max)) end) as $pad_spend |
              (if .max_budget then "$\(.max_budget)/day" else "unlimited" end) as $budget |
              "    \($padded)  \($pad_spend)  \($budget)"
            ),
            ""
          end'
      fi

      # Today's summary
      local today
      today=$(date -u +%Y-%m-%d)
      echo "$logs" | jq -r --arg today "$today" '
        map(select(.startTime[:10] == $today and .model_group != null and .model_group != "")) |
        if length == 0 then "  Today: no requests yet"
        else
          "  Today: \(length) requests  ·  $\(map(.spend // 0) | add | . * 10000 | round / 10000) spent  ·  \(map(.total_tokens // 0) | add) tokens"
        end'
      echo

      echo "Subcommands:  spend keys | spend models | spend daily [N] | spend today | spend infra [N]"
      ;;
  esac
}

cmd_monitor() {
  local live=false
  local interval=2
  local log_count=15

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --live) live=true; shift ;;
      --interval) interval="${2:?--interval requires seconds}"; shift 2 ;;
      --count) log_count="${2:?--count requires a number}"; shift 2 ;;
      *) echo "Unknown option: $1"; echo "Usage: rockport monitor [--live] [--interval N] [--count N]"; return 1 ;;
    esac
  done

  local url key today
  url="$(get_tunnel_url)"
  key="$(get_master_key)"
  today=$(date -u +%Y-%m-%d)

  render_monitor() {
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    # Fetch key list and spend logs in parallel
    local keys_data logs_data
    local cf_m_args=()
    if [[ -n "$CACHED_CF_CLIENT_ID" && -n "$CACHED_CF_CLIENT_SECRET" ]]; then
      cf_m_args=(-H "CF-Access-Client-Id: $CACHED_CF_CLIENT_ID" -H "CF-Access-Client-Secret: $CACHED_CF_CLIENT_SECRET")
    fi
    keys_data=$(curl -s "$url/key/list?return_full_object=true" \
      -H "Authorization: Bearer $key" "${cf_m_args[@]+"${cf_m_args[@]}"}" --max-time 10 2>/dev/null) || keys_data='{"keys":[]}'
    logs_data=$(curl -s "$url/spend/logs?start_date=$today" \
      -H "Authorization: Bearer $key" "${cf_m_args[@]+"${cf_m_args[@]}"}" --max-time 10 2>/dev/null) || logs_data='[]'

    # Header
    echo "Rockport Monitor                                    $now"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo

    # Keys table
    echo "$keys_data" | jq -r --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      (.keys // .) | map(select(type == "object")) |
      if length == 0 then
        "  No keys.\n"
      else
        "  Key                     Spend      Budget       Models     Last Active",
        "  ────────────────────────────────────────────────────────────────────────────",
        (sort_by(.last_active // "0") | reverse | .[] |
          (.key_alias // .key_name // "unnamed") as $name |
          ($name | if length > 22 then .[0:22] else . + (" " * ([22 - length, 0] | max)) end) as $pad_name |

          # Spend
          ("$\(.spend // 0 | . * 1000 | round / 1000 | tostring)" |
            if length > 9 then .[0:9] else . + (" " * ([9 - length, 0] | max)) end) as $pad_spend |

          # Budget
          (if .max_budget then "$\(.max_budget)/day" else "unlimited" end |
            if length > 11 then .[0:11] else . + (" " * ([11 - length, 0] | max)) end) as $pad_budget |

          # Models
          (if .models and (.models | length) > 0 then "restricted" else "all" end |
            if length > 9 then .[0:9] else . + (" " * ([9 - length, 0] | max)) end) as $pad_models |

          # Last active (relative)
          (if .last_active then
            (($now | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
             (.last_active | sub("\\.[0-9]+.*"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) |
            if . < 0 then "just now"
            elif . < 60 then "\(. | floor)s ago"
            elif . < 3600 then "\(. / 60 | floor)m ago"
            elif . < 86400 then "\(. / 3600 | floor)h ago"
            else "\(. / 86400 | floor)d ago"
            end
          else "never" end) as $last |

          "  \($pad_name)  \($pad_spend)  \($pad_budget)  \($pad_models)  \($last)"
        ),
        ""
      end'

    # Recent requests
    local count="$1"
    echo "$logs_data" | jq -r --argjson n "$count" '
      [.[] | select(.metadata.user_api_key_alias != null and .metadata.user_api_key_alias != "litellm-internal-health-check" and .model_group != "" and .model_group != null)] |
      sort_by(.startTime) | reverse | .[0:$n] |
      if length == 0 then
        "  Recent Requests",
        "  ────────────────────────────────────────────────────────────────────────────",
        "  No requests today.\n"
      else
        "  Recent Requests (today, newest first)",
        "  ────────────────────────────────────────────────────────────────────────────",
        (.[] |
          (.startTime | split("T")[1] | split(".")[0]) as $time |
          (.metadata.user_api_key_alias // "?") as $alias |
          ($alias | if length > 16 then .[0:16] else . + (" " * ([16 - length, 0] | max)) end) as $pad_alias |
          (.model_group // "?" | if length > 20 then .[0:20] else . + (" " * ([20 - length, 0] | max)) end) as $pad_model |
          (if .total_tokens > 0 then "\(.total_tokens)tok"
           else "image" end |
            if length > 8 then .[0:8] else . + (" " * ([8 - length, 0] | max)) end) as $pad_tokens |
          ("$\(.spend // 0 | . * 10000 | round / 10000 | tostring)" |
            if length > 8 then .[0:8] else . + (" " * ([8 - length, 0] | max)) end) as $pad_cost |
          ("\(.request_duration_ms // 0)ms") as $dur |
          "  \($time)  \($pad_alias)  \($pad_model)  \($pad_tokens)  \($pad_cost)  \($dur)"
        ),
        ""
      end'

    # Today summary
    echo "$logs_data" | jq -r '
      [.[] | select(.metadata.user_api_key_alias != null and .metadata.user_api_key_alias != "litellm-internal-health-check" and .model_group != "" and .model_group != null)] |
      if length == 0 then empty
      else
        "  Today: \(length) requests  ·  $\(map(.spend // 0) | add | . * 1000 | round / 1000) spent  ·  \(map(.total_tokens // 0) | add) tokens"
      end'
  }

  if [[ "$live" == "true" ]]; then
    # Check for tput
    if ! command -v tput &>/dev/null; then
      echo "ERROR: tput required for --live mode" >&2
      return 1
    fi
    trap 'tput cnorm; echo; exit 0' INT TERM
    tput civis  # hide cursor
    while true; do
      tput clear
      render_monitor "$log_count"
      if [[ "$live" == "true" ]]; then
        echo
        echo "  Refreshing every ${interval}s · Press Ctrl+C to stop"
      fi
      sleep "$interval"
    done
  else
    render_monitor "$log_count"
  fi
}
