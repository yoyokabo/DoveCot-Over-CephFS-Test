#!/usr/bin/env bash
# =============================================================================
# mds-failover.sh — METADATA SERVER FAILOVER.
#
# Stops the ACTIVE MDS while load runs. The standby MDS is promoted and replays
# the journal; during that window CephFS metadata ops (and thus most IMAP
# activity, which is metadata-heavy — especially for maildir) STALL, then
# resume once the standby is active. We time how long until an MDS is active
# again, then restart the original so it returns as the standby spare.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source chaos/measure-recovery.sh

FS_NAME="${CEPHFS_NAME:-cephfs}"

# Which MDS daemon is currently active? Parse `ceph mds stat`, e.g.
#   cephfs:1 {0=mds-b=up:active} 1 up:standby   ->   mds-b
# (We avoid `ceph fs status`, whose tabular output contains ANSI color codes.)
active_mds() {
  ceph_q mds stat 2>/dev/null | sed -n 's/.*0=\([^=]*\)=up:active.*/\1/p'
}

wait_mds_active() {
  local timeout="${1:-120}" start; start="$(now)"
  echo "   waiting for an active MDS (timeout ${timeout}s)..."
  until ceph_q fs status "${FS_NAME}" 2>/dev/null | grep -q active; do
    if (( $(now) - start > timeout )); then chaos_mark "TIMEOUT waiting MDS active"; return 0; fi
    sleep 1
  done
  chaos_mark "RECOVERED MDS active again"
}

docker exec bench bash -c '[ -f /tmp/corpus.mbox ] || /opt/bench/gen-corpus.sh /tmp/corpus.mbox 25' >/dev/null
chaos_init "mds-failover"
chaos_start_load

VICTIM="$(active_mds)"; VICTIM="${VICTIM:-mds-a}"
chaos_mark "INJECT  stop active MDS = ${VICTIM} (standby should take over)"
docker compose stop "${VICTIM}" >/dev/null
T_INJECT="$(now)"

wait_mds_active 120
echo "   >> standby took over $(( $(now) - T_INJECT ))s after killing ${VICTIM}"

chaos_mark "RESTORE docker compose start ${VICTIM} (rejoins as standby)"
docker compose start "${VICTIM}" >/dev/null
chaos_wait_health_ok 120

chaos_settle 20
chaos_finish
