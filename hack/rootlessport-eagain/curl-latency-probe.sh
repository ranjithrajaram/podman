#!/bin/bash
# curl-latency-probe.sh
#
# Run from an EXTERNAL node to measure rootlessport packet-handling latency.
# Each request is fired sequentially so every slow response is individually
# visible — this is more useful than aggregate stats for spotting EAGAIN spikes.
#
# Usage:
#   bash curl-latency-probe.sh <host-ip-or-hostname> [port] [requests] [slow-threshold-ms]
#
# Examples:
#   bash curl-latency-probe.sh 10.0.1.50                  # 30 reqs to port 18081
#   bash curl-latency-probe.sh 10.0.1.50 18081 50         # 50 reqs
#   bash curl-latency-probe.sh 10.0.1.50 18081 50 1000    # flag >1000 ms as slow

HOST="${1:?Usage: $0 <host> [port] [requests] [slow-ms]}"
PORT="${2:-18081}"
REQUESTS="${3:-30}"
SLOW_MS="${4:-500}"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; NC='\033[0m'

URL="http://${HOST}:${PORT}/"

echo ""
echo "Target  : $URL"
echo "Requests: $REQUESTS sequential"
echo "Slow    : > ${SLOW_MS} ms flagged"
echo ""
printf "  %-5s  %-10s  %-10s  %-12s  %-6s  %s\n" \
    "Req#" "DNS (ms)" "TCP (ms)" "Total (ms)" "HTTP" "Status"
printf "  %-5s  %-10s  %-10s  %-12s  %-6s  %s\n" \
    "-----" "----------" "----------" "------------" "------" "------"

SLOW=0
ERRORS=0

for i in $(seq 1 "$REQUESTS"); do
    # curl -w tokens (all times in seconds, converted to ms via awk)
    RESULT=$(curl -s -o /dev/null \
        --max-time 60 \
        -w "%{time_namelookup} %{time_connect} %{time_total} %{http_code}" \
        "$URL" 2>/dev/null) || { RESULT="0 0 0 ERR"; ERRORS=$((ERRORS+1)); }

    DNS_S=$(  awk '{print $1}' <<< "$RESULT")
    CONN_S=$( awk '{print $2}' <<< "$RESULT")
    TOTAL_S=$(awk '{print $3}' <<< "$RESULT")
    CODE=$(   awk '{print $4}' <<< "$RESULT")

    # Convert to ms (awk handles floating-point; bash cannot)
    DNS_MS=$(  awk "BEGIN {printf \"%.1f\", $DNS_S   * 1000}")
    CONN_MS=$( awk "BEGIN {printf \"%.1f\", $CONN_S  * 1000}")
    TOTAL_MS=$(awk "BEGIN {printf \"%.1f\", $TOTAL_S * 1000}")

    IS_SLOW=$(awk "BEGIN {print ($TOTAL_MS > $SLOW_MS) ? 1 : 0}")

    if [[ "$CODE" == "ERR" ]]; then
        printf "  %-5d  %-10s  %-10s  %-12s  %-6s  " \
            "$i" "-" "-" "-" "ERROR"
        echo -e "${RED}[FAILED]${NC}"
    elif [[ "$IS_SLOW" -eq 1 ]]; then
        SLOW=$((SLOW + 1))
        printf "  %-5d  %-10s  %-10s  %-12s  %-6s  " \
            "$i" "${DNS_MS}ms" "${CONN_MS}ms" "${TOTAL_MS}ms" "$CODE"
        echo -e "${RED}*** SLOW — EAGAIN scheduler lag ***${NC}"
    else
        printf "  %-5d  %-10s  %-10s  %-12s  %-6s  " \
            "$i" "${DNS_MS}ms" "${CONN_MS}ms" "${TOTAL_MS}ms" "$CODE"
        echo -e "${GRN}OK${NC}"
    fi
done

echo ""
echo "========================================"
echo "Summary"
echo "========================================"
echo "  Total requests : $REQUESTS"
echo "  Errors         : $ERRORS"
if [[ "$SLOW" -gt 0 ]]; then
    echo -e "  Slow (>${SLOW_MS}ms)   : ${RED}${SLOW}${NC}  ← rootlessport EAGAIN lag confirmed"
else
    echo -e "  Slow (>${SLOW_MS}ms)   : ${GRN}0${NC}  (patched or insufficient load)"
fi
