#!/usr/bin/env bash
# Additional coverage for RAM Sentinel's report, webhook and log rotation paths.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/ram-sentinel.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"
cat > "$work/bin/sendmail" <<EOF_SENDMAIL
#!/usr/bin/env bash
cat >/dev/null
EOF_SENDMAIL
cat > "$work/bin/curl" <<EOF_CURL
#!/usr/bin/env bash
printf '%s\\n' "\$@" > "$work/curl-args"
exit 0
EOF_CURL
chmod +x "$work/bin/sendmail" "$work/bin/curl"
export PATH="$work/bin:$PATH"
export RAM_SENTINEL_MEMINFO="$work/meminfo"
export RAM_SENTINEL_STATE_DIR="$work/state"
export RAM_SENTINEL_TO=''
export RAM_SENTINEL_FROM=''
cat > "$work/meminfo" <<'EOF_MEM'
MemTotal:       16000000 kB
MemFree:        300000 kB
MemAvailable:   9000000 kB
Buffers:        200000 kB
Cached:         8000000 kB
SReclaimable:   500000 kB
Shmem:          100000 kB
SwapTotal:      2000000 kB
SwapFree:       1500000 kB
EOF_MEM
pass=0; fail=0
check() {
    if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "ok    $1"
    else fail=$((fail+1)); echo "FAIL  $1 (expected '$3', got '$2')"; fi
}

json="$(RAM_SENTINEL_MEMINFO="$work/meminfo" "$script" --json)"
check 'JSON output includes swap used' "$(grep -c '"used": 500000' <<<"$json")" 1

# Webhook-only delivery: curl is replaced with a local capture shim.
export RAM_SENTINEL_WEBHOOK='https://hooks.example.invalid/test'
export RAM_SENTINEL_WEBHOOK_FORMAT=slack
"$script"
check 'webhook-only mode delivers through curl shim' "$(grep -c -- '--data' "$work/curl-args")" 1
check 'Slack payload contains text field' "$(grep -c '{"text":"Hi Sam' "$work/curl-args")" 1

# One report is written for the day even when the webhook is invoked again.
"$script"
check 'webhook delivery is limited to once per day' "$(grep -c -- '--data' "$work/curl-args")" 1

# Discord expects a content field rather than Slack's text field.
echo 2000-01-01 > "$work/state/last_sent"
export RAM_SENTINEL_WEBHOOK_FORMAT=discord
"$script"
check 'Discord payload contains content field' "$(grep -c '{\"content\":\"Hi Sam' "$work/curl-args")" 1
export RAM_SENTINEL_WEBHOOK_FORMAT=slack

# The optional report mode reads the recorded CSV.
report="$(RAM_SENTINEL_WEBHOOK='' "$script" --report)"
check 'report mode includes average utilisation' "$(grep -c '^Average RAM utilisation:' <<<"$report")" 1
check 'report mode includes peak utilisation' "$(grep -c '^Peak RAM utilisation:' <<<"$report")" 1

# A preview must not expose the webhook token or alter the stored state.
preview_state="$work/preview-state"
preview="$(RAM_SENTINEL_STATE_DIR="$preview_state" RAM_SENTINEL_WEBHOOK='https://hooks.example.invalid/sensitive-token' \
    "$script" --dry-run)"
check 'dry-run never prints the webhook URL' "$(grep -c 'sensitive-token' <<<"$preview" || true)" 0
[[ ! -e "$preview_state" ]]; preview_status=$?
check 'dry-run does not create state directory' "$preview_status" 0

# A low rotation threshold makes the retention behaviour deterministic.
export RAM_SENTINEL_WEBHOOK=''
export RAM_SENTINEL_TO='to@example.com'
export RAM_SENTINEL_FROM='from@example.com'
export RAM_SENTINEL_THRESHOLD=100
export RAM_SENTINEL_LOG_LIMIT_BYTES=1
export RAM_SENTINEL_LOG_KEEP_ROWS=2
for _ in 1 2 3 4; do "$script"; done
check 'rotation preserves exactly one CSV header' "$(grep -c '^timestamp,' "$work/state/usage.csv")" 1
check 'rotation retains header plus two recent rows' "$(wc -l < "$work/state/usage.csv" | tr -d ' ')" 3

bad_webhook="$(RAM_SENTINEL_WEBHOOK='http://insecure.example.invalid/hook' "$script" --status >/dev/null 2>&1; echo $?)"
check 'non-HTTPS webhook is rejected' "${bad_webhook##*$'\n'}" 1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit "$fail"
