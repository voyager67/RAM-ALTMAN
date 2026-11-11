#!/usr/bin/env bash
#
# ram-sentinel.sh
# A Linux RAM monitor with a sense of humour and a suspiciously tidy audit trail.
# Tracks memory and (at most once per day) reports spare capacity to Sam.
#
# Usage:
#   ram-sentinel.sh                 Record a sample and send the daily report if due
#   ram-sentinel.sh --status        Print current RAM and swap figures
#   ram-sentinel.sh --dry-run       Preview the report without sending or writing state
#   ram-sentinel.sh --report        Summarise historical samples
#   ram-sentinel.sh --json          Print the current sample as JSON
#   ram-sentinel.sh --help          Show this help
#
# Cron (every five minutes):
#   */5 * * * * /path/to/ram-sentinel.sh
#
# Memory accounting:
#   used = MemTotal - MemAvailable
# MemAvailable is preferred because it accounts for memory the kernel can reclaim.
#
# License: Unlicense (see licenses/UNLICENSE.txt)

set -Eeuo pipefail
IFS=$'\n\t'

readonly APP_NAME='ram-sentinel'
readonly APP_VERSION='1.0.0'
readonly DEFAULT_THRESHOLD=10
readonly DEFAULT_LOG_LIMIT_BYTES=$((20 * 1024 * 1024))
readonly DEFAULT_LOG_KEEP_ROWS=100000

# Cron commonly omits system mailer locations from PATH.
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin:/usr/local/sbin:/usr/sbin:/sbin"

RECIPIENT="${RAM_SENTINEL_TO:-}"
SENDER="${RAM_SENTINEL_FROM:-}"
SENDER_NAME="${RAM_SENTINEL_FROM_NAME:-}"
THRESHOLD_PCT="${RAM_SENTINEL_THRESHOLD:-$DEFAULT_THRESHOLD}"
STATE_DIR="${RAM_SENTINEL_STATE_DIR:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/ram-sentinel}"
MEMINFO="${RAM_SENTINEL_MEMINFO:-/proc/meminfo}"
WEBHOOK_URL="${RAM_SENTINEL_WEBHOOK:-}"
WEBHOOK_FORMAT="${RAM_SENTINEL_WEBHOOK_FORMAT:-slack}"
WEBHOOK_TIMEOUT="${RAM_SENTINEL_WEBHOOK_TIMEOUT:-10}"
MAX_LOG_BYTES="${RAM_SENTINEL_LOG_LIMIT_BYTES:-$DEFAULT_LOG_LIMIT_BYTES}"
LOG_LINES_TO_KEEP="${RAM_SENTINEL_LOG_KEEP_ROWS:-$DEFAULT_LOG_KEEP_ROWS}"
LOCK_TIMEOUT="${RAM_SENTINEL_LOCK_TIMEOUT:-5}"

USAGE_LOG="$STATE_DIR/usage.csv"
LAST_SENT_FILE="$STATE_DIR/last_sent"
LOCK_FILE="$STATE_DIR/lock"

# Memory values are in KiB unless otherwise stated.
total_kb=0
available_kb=0
used_kb=0
free_kb=0
buffers_kb=0
cached_kb=0
slab_kb=0
shmem_kb=0
cache_kb=0
swap_total_kb=0
swap_free_kb=0
swap_used_kb=0
available_pct='0.0'
used_pct='0.0'
swap_used_pct='0.0'

# These values are assigned by compose_email().
email_subject=''
email_body=''

usage() {
    cat <<'USAGE'
ram-sentinel - a daily report from the RAM your machine has left available

Usage:
  ./ram-sentinel.sh                 Record a sample and send the daily report if due
  ./ram-sentinel.sh --status        Show current RAM and swap statistics
  ./ram-sentinel.sh --dry-run       Preview an email; never sends or writes state
  ./ram-sentinel.sh --report        Summarise the local CSV history
  ./ram-sentinel.sh --json          Print current statistics as JSON
  ./ram-sentinel.sh --version       Print version information
  ./ram-sentinel.sh --help          Show this help

Configuration (environment variables):
  RAM_SENTINEL_TO                 Email recipient (required for email delivery)
  RAM_SENTINEL_FROM               Sender address (required for email delivery)
  RAM_SENTINEL_FROM_NAME          Optional sender display name
  RAM_SENTINEL_THRESHOLD          Report when available RAM is above this % (10)
  RAM_SENTINEL_STATE_DIR          State and CSV directory
  RAM_SENTINEL_MEMINFO             Alternate meminfo path (primarily for tests)
  RAM_SENTINEL_WEBHOOK             Optional HTTPS webhook URL
  RAM_SENTINEL_WEBHOOK_FORMAT      'slack' or 'discord' (default: slack)
  RAM_SENTINEL_WEBHOOK_TIMEOUT     Webhook timeout in seconds (default: 10)
  RAM_SENTINEL_LOG_LIMIT_BYTES     Soft CSV rotation limit (default: 20 MiB)
  RAM_SENTINEL_LOG_KEEP_ROWS       Rows retained after rotation (default: 100000)
  RAM_SENTINEL_LOCK_TIMEOUT        Seconds to wait for the run lock (default: 5)

Scheduled mode needs a configured email transport, a webhook, or both.
Email transport: sendmail, msmtp or mail. Webhooks require curl.
Use --dry-run before enabling delivery. At most one successful report per day.
USAGE
}

die() {
    printf '%s: %s\n' "$APP_NAME" "$*" >&2
    exit 1
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_configuration() {
    is_uint "$THRESHOLD_PCT" || die 'RAM_SENTINEL_THRESHOLD must be an integer from 0 to 100'
    (( ${#THRESHOLD_PCT} <= 3 )) || die 'RAM_SENTINEL_THRESHOLD must be between 0 and 100'
    THRESHOLD_PCT=$((10#$THRESHOLD_PCT))
    (( THRESHOLD_PCT <= 100 )) || die 'RAM_SENTINEL_THRESHOLD must be between 0 and 100'

    is_uint "$MAX_LOG_BYTES" && (( ${#MAX_LOG_BYTES} <= 12 )) || die 'RAM_SENTINEL_LOG_LIMIT_BYTES must be a positive integer'
    is_uint "$LOG_LINES_TO_KEEP" && (( ${#LOG_LINES_TO_KEEP} <= 9 )) || die 'RAM_SENTINEL_LOG_KEEP_ROWS must be a positive integer'
    is_uint "$LOCK_TIMEOUT" && (( ${#LOCK_TIMEOUT} <= 4 )) || die 'RAM_SENTINEL_LOCK_TIMEOUT must be a non-negative integer'
    is_uint "$WEBHOOK_TIMEOUT" && (( ${#WEBHOOK_TIMEOUT} <= 4 )) || die 'RAM_SENTINEL_WEBHOOK_TIMEOUT must be a positive integer'
    MAX_LOG_BYTES=$((10#$MAX_LOG_BYTES))
    LOG_LINES_TO_KEEP=$((10#$LOG_LINES_TO_KEEP))
    LOCK_TIMEOUT=$((10#$LOCK_TIMEOUT))
    WEBHOOK_TIMEOUT=$((10#$WEBHOOK_TIMEOUT))
    (( MAX_LOG_BYTES > 0 && LOG_LINES_TO_KEEP > 0 && WEBHOOK_TIMEOUT > 0 )) || die 'log limits and webhook timeout must be positive'

    if [[ -n "$RECIPIENT" && ! "$RECIPIENT" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        die 'RAM_SENTINEL_TO must be a single valid-looking email address'
    fi
    if [[ -n "$SENDER" && ! "$SENDER" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        die 'RAM_SENTINEL_FROM must be a single valid-looking email address'
    fi
    [[ -z "$SENDER_NAME" || ( "$SENDER_NAME" != *$'\n'* && "$SENDER_NAME" != *$'\r'* ) ]] || die 'RAM_SENTINEL_FROM_NAME must not contain line breaks'
    [[ -z "$RECIPIENT" || -n "$SENDER" ]] || die 'RAM_SENTINEL_FROM is required when RAM_SENTINEL_TO is set'
    [[ -z "$SENDER" || -n "$RECIPIENT" ]] || die 'RAM_SENTINEL_TO is required when RAM_SENTINEL_FROM is set'

    if [[ -n "$WEBHOOK_URL" ]]; then
        [[ "$WEBHOOK_URL" == https://* && "$WEBHOOK_URL" != *$'\n'* && "$WEBHOOK_URL" != *$'\r'* ]] || die 'RAM_SENTINEL_WEBHOOK must be an HTTPS URL without line breaks'
        [[ "$WEBHOOK_FORMAT" == slack || "$WEBHOOK_FORMAT" == discord ]] || die 'RAM_SENTINEL_WEBHOOK_FORMAT must be slack or discord'
    fi
}

ensure_state_dir() {
    umask 077
    mkdir -p -- "$STATE_DIR" || die "cannot create state directory: $STATE_DIR"
    chmod 700 -- "$STATE_DIR" 2>/dev/null || true
}

# Parse /proc/meminfo into a simple whitespace-delimited record. This avoids
# process substitution and keeps awk's output easy to validate before read.
read_memory() {
    [[ -r "$MEMINFO" ]] || die "cannot read $MEMINFO (Linux procfs is required)"

    local parsed
    parsed="$(awk '
        /^MemTotal:/      { total = $2 }
        /^MemFree:/       { free = $2 }
        /^MemAvailable:/  { available = $2; has_available = 1 }
        /^Buffers:/       { buffers = $2 }
        /^Cached:/        { cached = $2 }
        /^SReclaimable:/  { slab = $2 }
        /^Shmem:/         { shmem = $2 }
        /^SwapTotal:/     { swap_total = $2 }
        /^SwapFree:/      { swap_free = $2 }
        END {
            if (total <= 0) exit 2
            cache = buffers + cached + slab - shmem
            if (cache < 0) cache = 0
            # Fallback estimate for kernels without MemAvailable.
            if (!has_available) available = free + cache
            if (available < 0) available = 0
            if (available > total) available = total
            if (free < 0) free = 0
            if (swap_total < 0) swap_total = 0
            if (swap_free < 0) swap_free = 0
            if (swap_free > swap_total) swap_free = swap_total
            printf "%.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f %.0f\n", \
                total, available, free, buffers, cached, slab, shmem, swap_total, swap_free
        }
    ' "$MEMINFO")" || die "MemTotal missing or invalid in $MEMINFO"

    IFS=' ' read -r total_kb available_kb free_kb buffers_kb cached_kb slab_kb shmem_kb \
        swap_total_kb swap_free_kb <<< "$parsed"
    (( total_kb > 0 )) || die "MemTotal missing or zero in $MEMINFO"

    used_kb=$((total_kb - available_kb))
    cache_kb=$((buffers_kb + cached_kb + slab_kb - shmem_kb))
    (( cache_kb >= 0 )) || cache_kb=0
    swap_used_kb=$((swap_total_kb - swap_free_kb))
    available_pct="$(awk -v a="$available_kb" -v t="$total_kb" 'BEGIN { printf "%.1f", a * 100 / t }')"
    used_pct="$(awk -v u="$used_kb" -v t="$total_kb" 'BEGIN { printf "%.1f", u * 100 / t }')"
    if (( swap_total_kb > 0 )); then
        swap_used_pct="$(awk -v u="$swap_used_kb" -v t="$swap_total_kb" 'BEGIN { printf "%.1f", u * 100 / t }')"
    else
        swap_used_pct='0.0'
    fi
}

to_gib() {
    awk -v kb="${1:-0}" 'BEGIN { printf "%.1f GiB", kb / 1048576 }'
}

to_mib() {
    awk -v kb="${1:-0}" 'BEGIN { printf "%.1f MiB", kb / 1024 }'
}

is_over_threshold() {
    awk -v a="$available_kb" -v t="$total_kb" -v p="$THRESHOLD_PCT" \
        'BEGIN { exit !(a * 100 > t * p) }'
}

print_status() {
    printf 'RAM Sentinel %s\n' "$APP_VERSION"
    printf '%s\n' '----------------------------------------'
    printf 'Total:      %s\n' "$(to_gib "$total_kb")"
    printf 'Used:       %s (%s%%)\n' "$(to_gib "$used_kb")" "$used_pct"
    printf 'Available:  %s (%s%%)\n' "$(to_gib "$available_kb")" "$available_pct"
    printf '  Free:     %s\n' "$(to_gib "$free_kb")"
    printf '  Cache:    %s\n' "$(to_gib "$cache_kb")"
    printf 'Swap:       %s used of %s (%s%%)\n' \
        "$(to_gib "$swap_used_kb")" "$(to_gib "$swap_total_kb")" "$swap_used_pct"
    if is_over_threshold; then
        printf 'Threshold:  crossed (> %s%% available)\n' "$THRESHOLD_PCT"
    else
        printf 'Threshold:  not crossed (> %s%% available)\n' "$THRESHOLD_PCT"
    fi
}

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

print_json() {
    local eligible=false
    is_over_threshold && eligible=true || true
    printf '{\n'
    printf '  "version": "%s",\n' "$APP_VERSION"
    printf '  "dispatch_eligible": %s,\n' "$eligible"
    printf '  "memory_kib": {"total": %s, "used": %s, "available": %s, "free": %s, "cache": %s},\n' \
        "$total_kb" "$used_kb" "$available_kb" "$free_kb" "$cache_kb"
    printf '  "memory_percent": {"used": %s, "available": %s},\n' "$used_pct" "$available_pct"
    printf '  "swap_kib": {"total": %s, "used": %s, "free": %s},\n' \
        "$swap_total_kb" "$swap_used_kb" "$swap_free_kb"
    printf '  "swap_used_percent": %s\n' "$swap_used_pct"
    printf '}\n'
}

log_sample() {
    local timestamp
    timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    if [[ ! -e "$USAGE_LOG" ]]; then
        printf 'timestamp,total_kb,used_kb,available_kb,available_pct,free_kb,cache_kb,swap_total_kb,swap_free_kb,swap_used_kb,swap_used_pct\n' > "$USAGE_LOG"
        chmod 600 "$USAGE_LOG"
    fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$timestamp" "$total_kb" "$used_kb" "$available_kb" "$available_pct" \
        "$free_kb" "$cache_kb" "$swap_total_kb" "$swap_free_kb" "$swap_used_kb" "$swap_used_pct" >> "$USAGE_LOG"
    chmod 600 "$USAGE_LOG"

    local current_bytes temporary
    current_bytes="$(wc -c < "$USAGE_LOG")"
    if (( current_bytes > MAX_LOG_BYTES )); then
        temporary="$(mktemp "$STATE_DIR/.usage.XXXXXX")"
        {
            head -n 1 "$USAGE_LOG"
            tail -n +2 "$USAGE_LOG" | tail -n "$LOG_LINES_TO_KEEP"
        } > "$temporary"
        chmod 600 "$temporary"
        mv -f -- "$temporary" "$USAGE_LOG"
    fi
}

# Each category uses its own shuffled bag. Every entry is used once before a
# new bag is dealt, and the first entry of a new bag cannot repeat the previous
# cycle's final entry. Dry runs do not create or modify state files.
pick_index() {
    local category="$1" count="$2" bag last first selected temporary
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        printf '%s' "$((RANDOM % count))"
        return 0
    fi

    bag="$STATE_DIR/bag_${category}"
    if [[ ! -s "$bag" ]]; then
        temporary="$(mktemp "$STATE_DIR/.bag.XXXXXX")"
        shuf -i "0-$((count - 1))" -n "$count" > "$temporary"
        last=''
        [[ ! -r "$bag.last" ]] || last="$(<"$bag.last")"
        first="$(head -n 1 "$temporary")"
        if (( count > 1 )) && [[ "$first" == "$last" ]]; then
            {
                sed -n '2p' "$temporary"
                sed -n '1p' "$temporary"
                tail -n +3 "$temporary"
            } > "$temporary.reordered"
            mv -f -- "$temporary.reordered" "$temporary"
        fi
        mv -f -- "$temporary" "$bag"
    fi

    selected="$(head -n 1 "$bag")"
    temporary="$(mktemp "$STATE_DIR/.bag.XXXXXX")"
    tail -n +2 "$bag" > "$temporary"
    mv -f -- "$temporary" "$bag"
    printf '%s\n' "$selected" > "$bag.last"
    printf '%s' "$selected"
}

compose_email() {
    local total available pct swap_total swap_used
    total="$(to_gib "$total_kb")"
    available="$(to_gib "$available_kb")"
    pct="$available_pct"
    swap_total="$(to_gib "$swap_total_kb")"
    swap_used="$(to_gib "$swap_used_kb")"

    local -a subjects=(
        'A small allocation discrepancy'
        'A routine report from one workstation'
        'Unused memory has been located'
        'A desktop has filed its daily statement'
        'Some DRAM remains outside the data centre'
        'The available-memory situation persists'
        'A note from the free-memory district'
        'One machine, several idle GiB'
        'The RAM ledger has another entry'
        'A small update for the global allocation desk'
        'Memory availability: nothing to see here'
        'Your daily workstation capacity report'
    )
    local -a bodies=(
        "This workstation has located $available of available RAM out of $total installed. It remains unclear why nobody has collected it."
        "The latest inspection found $pct% of installed memory available, or $available. The machine continues to describe this as normal operation."
        "I checked the numbers before writing: $total is installed, $available is available, and the page cache has been treated fairly."
        "A modest quantity of memory remains unclaimed on this desk: $available, representing $pct% of the installed capacity."
        "Today's machine report contains one notable finding: $available of RAM is available and has not submitted a data-centre transfer request."
        "The local memory ledger reads $total installed and $available available. I have retained the evidence in CSV for the relevant authorities."
        "Even after the usual browser activity, this PC reports $available available. I thought the global allocation team might appreciate the update."
        "For completeness, the workstation is using $(to_gib "$used_kb") and has $available available. Neither figure appears particularly concerned."
        "The available-memory counter has reached $pct%, which is $available in ordinary units. This is a status report, not a negotiation."
        "I have reviewed the reclaimable cache and the kernel's estimate. The remaining available amount is $available, and the audit trail is attached locally."
        "The installed total is $total. The currently available portion is $available. The discrepancy is being monitored at five-minute intervals."
        "A short operational update: $available remains available on this machine. Swap usage is $swap_used of $swap_total, should that be relevant to the discussion."
    )
    local -a signoffs=(
        'Yours in underutilised abundance,'
        'Respectfully, with capacity to spare,'
        'Keeping the allocation conversation alive,'
        'Hoarding responsibly, for now,'
        'Regards from the free-memory district,'
        'Sent from a workstation with room to spare,'
        'Yours, pending further allocation guidance,'
        'With several GiB still at liberty,'
    )

    local subject_index body_index signoff_index
    subject_index="$(pick_index subject "${#subjects[@]}")"
    body_index="$(pick_index body "${#bodies[@]}")"
    signoff_index="$(pick_index signoff "${#signoffs[@]}")"

    email_subject="${subjects[$subject_index]}"
    email_body="Hi Sam,

${bodies[$body_index]}

Machine summary:
  Installed:  $total
  Used:       $(to_gib "$used_kb") (${used_pct}%)
  Available:  $available (${pct}%)
  Swap:       $swap_used used of $swap_total (${swap_used_pct}%)

${signoffs[$signoff_index]}
${SENDER_NAME:-A concerned RAM owner}

--
Generated automatically by RAM Sentinel. This is a parody report, not an
OpenAI service or an operational request. The recipient was configured by
the operator of this machine. Stop sending if the recipient asks you to stop."
}

render_email() {
    local from_header="${SENDER:-sender-not-configured@example.invalid}"
    local to_header="${RECIPIENT:-recipient-not-configured@example.invalid}"
    [[ -z "$SENDER_NAME" ]] || from_header="$SENDER_NAME <$from_header>"
    printf 'From: %s\n' "$from_header"
    printf 'To: %s\n' "$to_header"
    printf 'Subject: %s\n' "$email_subject"
    printf 'Date: %s\n' "$(date -R)"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf 'Auto-Submitted: auto-generated\n'
    printf '\n%s\n' "$email_body"
}

send_email() {
    if command -v sendmail >/dev/null 2>&1; then
        render_email | sendmail -t -i
    elif command -v msmtp >/dev/null 2>&1; then
        render_email | msmtp -t
    elif command -v mail >/dev/null 2>&1; then
        printf '%s\n' "$email_body" | mail -s "$email_subject" "$RECIPIENT"
    else
        printf '%s: no sendmail, msmtp or mail command found\n' "$APP_NAME" >&2
        return 1
    fi
}

send_webhook() {
    local payload escaped
    escaped="$(json_escape "$email_body")"
    if [[ "$WEBHOOK_FORMAT" == discord ]]; then
        payload="{\"content\":\"$escaped\"}"
    else
        payload="{\"text\":\"$escaped\"}"
    fi
    command -v curl >/dev/null 2>&1 || die 'curl is required when RAM_SENTINEL_WEBHOOK is configured'
    curl --fail --silent --show-error --max-time "$WEBHOOK_TIMEOUT" \
        --header 'Content-Type: application/json' --data "$payload" "$WEBHOOK_URL" >/dev/null
}

send_notifications() {
    if [[ -n "$RECIPIENT" ]]; then
        send_email || return 1
    fi
    if [[ -n "$WEBHOOK_URL" ]]; then
        send_webhook || return 1
    fi
}

write_last_sent() {
    local today="$1" temporary
    temporary="$(mktemp "$STATE_DIR/.last-sent.XXXXXX")"
    printf '%s\n' "$today" > "$temporary"
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$LAST_SENT_FILE"
}

run_scheduled() {
    [[ -n "$RECIPIENT" || -n "$WEBHOOK_URL" ]] || die 'configure RAM_SENTINEL_TO and RAM_SENTINEL_FROM, or set RAM_SENTINEL_WEBHOOK'
    command -v flock >/dev/null 2>&1 || die 'flock is required for scheduled mode'
    if [[ -n "$WEBHOOK_URL" ]]; then
        command -v curl >/dev/null 2>&1 || die 'curl is required when RAM_SENTINEL_WEBHOOK is configured'
    fi

    ensure_state_dir
    exec 9> "$LOCK_FILE"
    flock -w "$LOCK_TIMEOUT" 9 || die "could not acquire the run lock within ${LOCK_TIMEOUT}s"

    read_memory
    log_sample
    is_over_threshold || exit 0

    local today last_sent
    today="$(date '+%F')"
    last_sent=''
    [[ ! -r "$LAST_SENT_FILE" ]] || last_sent="$(<"$LAST_SENT_FILE")"
    [[ "$last_sent" != "$today" ]] || exit 0

    compose_email
    send_notifications || die 'notification delivery failed; the next scheduled run will retry'
    write_last_sent "$today"
}

print_report() {
    [[ -r "$USAGE_LOG" ]] || die "no history found at $USAGE_LOG; run scheduled sampling first"
    awk -F, '
        NR == 1 { next }
        NF >= 11 && $2 > 0 {
            samples++
            used = ($3 / $2) * 100
            available = $5 + 0
            swap = $11 + 0
            used_sum += used
            available_sum += available
            swap_sum += swap
            if (samples == 1 || used > peak_used) peak_used = used
            if (samples == 1 || available < lowest_available) lowest_available = available
            if (samples == 1 || available > highest_available) highest_available = available
            if (samples == 1 || swap > peak_swap) peak_swap = swap
            if (!first) first = $1
            last = $1
        }
        END {
            if (!samples) {
                print "No samples recorded yet."
                exit 0
            }
            print "RAM Sentinel report"
            print "----------------------------------------"
            printf "Samples:                 %d\n", samples
            printf "First sample:            %s\n", first
            printf "Latest sample:           %s\n", last
            printf "Average RAM utilisation: %.1f%%\n", used_sum / samples
            printf "Peak RAM utilisation:    %.1f%%\n", peak_used
            printf "Average available RAM:   %.1f%%\n", available_sum / samples
            printf "Lowest available RAM:    %.1f%%\n", lowest_available
            printf "Highest available RAM:   %.1f%%\n", highest_available
            printf "Average swap utilisation:%.1f%%\n", swap_sum / samples
            printf "Peak swap utilisation:   %.1f%%\n", peak_swap
        }
    ' "$USAGE_LOG"
}

main() {
    case "${1:---run}" in
        --help|-h)
            usage
            ;;
        --version)
            printf '%s %s\n' "$APP_NAME" "$APP_VERSION"
            ;;
        --status)
            validate_configuration
            read_memory
            print_status
            ;;
        --json)
            validate_configuration
            read_memory
            print_json
            ;;
        --dry-run)
            validate_configuration
            DRY_RUN=1
            read_memory
            print_status
            compose_email
            printf '\n--- Email preview (not sent) ---\n'
            render_email
            if [[ -n "$WEBHOOK_URL" ]]; then
                printf '\nWebhook configured (%s format; not sent).\n' "$WEBHOOK_FORMAT"
            fi
            ;;
        --report)
            validate_configuration
            print_report
            ;;
        --run|'')
            validate_configuration
            run_scheduled
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
}

main "$@"
