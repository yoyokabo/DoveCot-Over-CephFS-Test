#!/usr/bin/env bash
# =============================================================================
# osd-down.sh — SINGLE OSD FAILURE + self-heal.
#
# Stops one OSD (osd2 == rack2) while imaptest drives load. With size=3 across
# 4 racks, Ceph re-replicates the lost copies onto the spare rack4 and returns
# to active+clean ALL ON ITS OWN — that backfill is the recovery we time. Then
# we bring the OSD back and wait for the cluster to settle to HEALTH_OK.
#
# Expected story in the timeline: brief latency bump at fault, cluster stays
# AVAILABLE throughout (reads/writes keep succeeding off the 2 surviving
# copies), PGs return to active+clean after backfill.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source chaos/measure-recovery.sh

VICTIM="${VICTIM:-osd2}"   # the OSD/rack to kill

docker exec bench bash -c '[ -f /tmp/corpus.mbox ] || /opt/bench/gen-corpus.sh /tmp/corpus.mbox 25' >/dev/null
chaos_init "osd-down-${VICTIM}"
chaos_start_load

chaos_mark "INJECT  docker compose stop ${VICTIM} (lose one rack's replica)"
docker compose stop "${VICTIM}" >/dev/null
T_INJECT="$(now)"

# Recovery #1: Ceph self-heals by backfilling the missing copies onto rack4.
chaos_wait_pgs_clean 240
echo "   >> self-heal (backfill) took $(( $(now) - T_INJECT ))s"

chaos_mark "RESTORE docker compose start ${VICTIM}"
docker compose start "${VICTIM}" >/dev/null

# Recovery #2: OSD rejoins, cluster rebalances back and returns to HEALTH_OK.
chaos_wait_health_ok 240

chaos_settle 20
chaos_finish
