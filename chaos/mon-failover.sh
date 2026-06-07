#!/usr/bin/env bash
# =============================================================================
# mon-failover.sh — MONITOR FAILOVER (kill 1 of 3, quorum survives).
#
# Stops one monitor while load runs. With 3 mons, the remaining 2 keep quorum
# (majority), so the cluster stays fully available; if we killed the leader the
# other two re-elect a new one in ~seconds. This is the reassuring HA result:
# clients should see at most a brief blip. Then we restart the mon and confirm
# it rejoins to a clean 3/3 quorum.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source chaos/measure-recovery.sh

VICTIM="${VICTIM:-mon1}"   # mon1 is the initial leader in our bootstrap

docker exec bench bash -c '[ -f /tmp/corpus.mbox ] || /opt/bench/gen-corpus.sh /tmp/corpus.mbox 25' >/dev/null
chaos_init "mon-failover-${VICTIM}"
chaos_start_load

chaos_mark "BEFORE quorum: $(ceph_q quorum_status 2>/dev/null | grep -o '\"quorum_names\":\[[^]]*\]' || echo n/a)"
chaos_mark "INJECT  docker compose stop ${VICTIM} (1 of 3 mons)"
docker compose stop "${VICTIM}" >/dev/null
T_INJECT="$(now)"

# The cluster should stay responsive on the surviving 2/3 quorum.
chaos_wait_responsive 60
echo "   >> cluster responsive again $(( $(now) - T_INJECT ))s after killing ${VICTIM}"
chaos_mark "AFTER  quorum: $(ceph_q quorum_status 2>/dev/null | grep -o '\"quorum_names\":\[[^]]*\]' || echo n/a)"

chaos_mark "RESTORE docker compose start ${VICTIM}"
docker compose start "${VICTIM}" >/dev/null
chaos_wait_health_ok 120

chaos_settle 20
chaos_finish
