#!/usr/bin/env bash
# =============================================================================
# mon-quorumloss.sh — MONITOR QUORUM LOSS (kill 2 of 3).
#
# Stops TWO monitors, leaving only one — below the majority needed for quorum.
# The monitor cluster stops serving: clients can no longer get fresh cluster
# maps and I/O STALLS until quorum is restored. This is the tolerance-boundary
# result (contrast with mon-failover.sh, where 2/3 survive and nothing stalls).
# Recovery = restart one mon to rebuild a 2/3 majority.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source chaos/measure-recovery.sh

V1="${V1:-mon1}"; V2="${V2:-mon2}"   # kill two, leave mon3 alone

docker exec bench bash -c '[ -f /tmp/corpus.mbox ] || /opt/bench/gen-corpus.sh /tmp/corpus.mbox 25' >/dev/null
chaos_init "mon-quorumloss"
chaos_start_load

chaos_mark "INJECT  stop ${V1} + ${V2} (only 1/3 mons left -> NO quorum)"
docker compose stop "${V1}" "${V2}" >/dev/null
T_INJECT="$(now)"

# With no quorum, `ceph` commands will hang/fail. Hold the outage briefly so
# the client-side stall is visible in the timeline, then restore quorum.
chaos_mark "OUTAGE  holding no-quorum state ~30s (client I/O should stall)"
sleep 30

chaos_mark "RESTORE docker compose start ${V1} (back to 2/3 quorum)"
docker compose start "${V1}" >/dev/null
chaos_wait_responsive 120
echo "   >> mons answered again $(( $(now) - T_INJECT ))s after quorum loss"
chaos_wait_health_ok 120

chaos_settle 20
chaos_finish
