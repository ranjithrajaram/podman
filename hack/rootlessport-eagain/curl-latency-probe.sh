#!/bin/bash
# curl-latency-probe.sh
#
# Run from an EXTERNAL node to measure rootlessport packet-handling latency.
# Each request is fired sequentially so every slow response is individually
# visible — this is more useful than aggregate stats for spotting EAGAIN spikes.
#
# Usage:
#   bash curl-latency-probe.sh <host> [port] [requests] [slow-ms] [--stop-on-slow] [--interval S]
#
# Arguments:
#   host         Target IP or hostname
#   port         Port to probe (default: 18081)
#   requests     Max number of requests, 0 = run until Ctrl-C (default: 30)
#   slow-ms      Threshold in ms above which a request is flagged (default: 500)
#
# Options:
#   --stop-on-slow   Stop immediately when the first slow request is detected
#                    and print a full summary.
#   --interval S     Wait S seconds between probes (default: 0 = back-to-back).
#                    Useful to simulate periodic monitoring (e.g. --interval 30).
#
# Examples:
#   # Run 30 back-to-back requests, flag >500ms
#   bash curl-latency-probe.sh 192.168.122.192
#
#   # Run until a delay >1000ms is seen, then stop
#   bash curl-latency-probe.sh 192.168.122.192 18081 0 1000 --stop-on-slow
#
#   # Probe every 30 seconds indefinitely, stop on first slow response
#   bash curl-latency-probe.sh 192.168.122.192 18081 0 1000 --stop-on-slow --interval 30
#
#   # Fixed 60 probes with 10-second gap between each
#   bash curl-latency-probe.sh 192.168.122.192 18081 60 500 --interval 10

HOST="${1:?Usage: $0 <host> [port] [requests] [slow-ms] [--stop-on-slow]}"
PORT="${2:-18081}"
REQUESTS="${3:-30}"
SLOW_MS="${4:-500}"

STOP_ON_SLOW=0
INTERVAL=0
args=("$@")
for idx in "${!args[@]}"; do
    [[ "${args[$idx]}" == "--stop-on-slow" ]] && STOP_ON_SLOW=1
    if [[ "${args[$idx]}" == "--interval" ]]; then
        INTERVAL="${args[$((idx+1))]:-0}"
    fi
done

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'

URL="http://${HOST}:${PORT}/"

echo ""
echo "Target       : $URL"
if [[ "$REQUESTS" -eq 0 ]]; then
    echo "Requests     : unlimited (Ctrl-C to stop)"
else
    echo "Requests     : $REQUESTS sequential"
fi
echo "Slow flag    : > ${SLOW_MS} ms"
if [[ "$INTERVAL" -gt 0 ]]; then
    echo "Interval     : ${INTERVAL}s between probes"
fi
if [[ "$STOP_ON_SLOW" -eq 1 ]]; then
    echo "Mode         : stop on first slow response"
fi
echo ""
printf "  %-5s  %-10s  %-10s  %-12s  %-6s  %s\n" \
    "Req#" "DNS (ms)" "TCP (ms)" "Total (ms)" "HTTP" "Status"
printf "  %-5s  %-10s  %-10s  %-12s  %-6s  %s\n" \
    "-----" "----------" "----------" "------------" "------" "------"

SLOW=0
ERRORS=0
i=0

while true; do
    i=$((i + 1))

    RESULT=$(curl -s -o /dev/null \
        --max-time 60 \
        -w "%{time_namelookup} %{time_connect} %{time_total} %{http_code}" \
        "$URL" 2>/dev/null) || { RESULT="0 0 0 ERR"; ERRORS=$((ERRORS+1)); }

    DNS_S=$(  awk '{print $1}' <<< "$RESULT")
    CONN_S=$( awk '{print $2}' <<< "$RESULT")
    TOTAL_S=$(awk '{print $3}' <<< "$RESULT")
    CODE=$(   awk '{print $4}' <<< "$RESULT")

    DNS_MS=$(  awk "BEGIN {printf \"%.1f\", $DNS_S   * 1000}")
    CONN_MS=$( awk "BEGIN {printf \"%.1f\", $CONN_S  * 1000}")
    TOTAL_MS=$(awk "BEGIN {printf \"%.1f\", $TOTAL_S * 1000}")

    IS_SLOW=$(awk "BEGIN {print ($TOTAL_MS > $SLOW_MS) ? 1 : 0}")

    if [[ "$CODE" == "ERR" ]]; then
        printf "  %-5d  %-10s  %-10s  %-12s  %-6s  " \
            "$i" "-" "-" "-" "ERROR"
        echo -e "${RED}[FAILED]${NC}"
        ERRORS=$((ERRORS+1))
    elif [[ "$IS_SLOW" -eq 1 ]]; then
        SLOW=$((SLOW + 1))
        printf "  %-5d  %-10s  %-10s  %-12s  %-6s  " \
            "$i" "${DNS_MS}ms" "${CONN_MS}ms" "${TOTAL_MS}ms" "$CODE"
        echo -e "${RED}*** SLOW — EAGAIN scheduler lag ***${NC}"

        if [[ "$STOP_ON_SLOW" -eq 1 ]]; then
            echo ""
            echo -e "${YLW}Stopping: slow response detected on request #${i} (${TOTAL_MS}ms > ${SLOW_MS}ms)${NC}"
            break
        fi
    else
        printf "  %-5d  %-10s  %-10s  %-12s  %-6s  " \
            "$i" "${DNS_MS}ms" "${CONN_MS}ms" "${TOTAL_MS}ms" "$CODE"
        echo -e "${GRN}OK${NC}"
    fi

    # Stop after fixed request count (0 = unlimited)
    if [[ "$REQUESTS" -gt 0 && "$i" -ge "$REQUESTS" ]]; then
        break
    fi

    # Wait between probes if interval is set
    if [[ "$INTERVAL" -gt 0 ]]; then
        printf "  %s  (next probe in %ss)\r" "$(date +'%H:%M:%S')" "$INTERVAL"
        sleep "$INTERVAL"
        printf "%-60s\r" ""   # clear the waiting line
    fi
done

echo ""
echo "========================================"
echo "Summary"
echo "========================================"
echo "  Requests fired : $i"
echo "  Errors         : $ERRORS"
if [[ "$SLOW" -gt 0 ]]; then
    echo -e "  Slow (>${SLOW_MS}ms)    : ${RED}${SLOW}${NC}  ← rootlessport EAGAIN lag confirmed"
    if [[ "$STOP_ON_SLOW" -eq 1 ]]; then
        echo -e "  ${YLW}Probe stopped on first slow response (request #${i})${NC}"
    fi
else
    echo -e "  Slow (>${SLOW_MS}ms)    : ${GRN}0${NC}  (patched binary or insufficient load)"
fi
