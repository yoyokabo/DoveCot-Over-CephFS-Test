#!/usr/bin/env bash
# =============================================================================
# entrypoint-mon.sh — runs a Ceph MONITOR.
#
# Monitors are the brain of the cluster: they hold the authoritative cluster
# maps (monmap, osdmap, crushmap, fsmap) and form a Paxos quorum. We run THREE
# of them so the cluster tolerates losing one (failover test) and so we can
# also demonstrate quorum LOSS by killing two (quorum-loss test).
#
# Env (set per-container in docker-compose.yml):
#   MON_ID         logical id of this mon (mon1 / mon2 / mon3)
#   MON_PRIMARY    "1" only for mon1 — the one that bootstraps the cluster
#   plus the cluster vars from .env (CEPH_FSID, MON*_IP, subnet, ...)
# =============================================================================
set -euo pipefail
source /opt/ceph-scripts/lib.sh

DATADIR="/var/lib/ceph/mon/ceph-${MON_ID}"

if [[ "${MON_PRIMARY:-0}" == "1" ]]; then
  # The primary mon creates all shared artifacts, then signals the others.
  bootstrap_cluster
  mkfs_mon "${MON_ID}"
  touch "${BOOTSTRAP_DONE}"
else
  # Secondary mons wait for the primary, then format their own store from the
  # SAME monmap + mon keyring so they join the existing cluster.
  wait_for_bootstrap
  mkfs_mon "${MON_ID}"
fi

own_ceph "${DATADIR}"
log "starting ceph-mon ${MON_ID}"
# -f = foreground (PID 1 in the container). --setuser/group drop to 'ceph'.
exec ceph-mon -i "${MON_ID}" -f --setuser ceph --setgroup ceph
