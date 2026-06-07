#!/usr/bin/env bash
# =============================================================================
# entrypoint-mgr.sh — runs a Ceph MANAGER (ceph-mgr).
#
# The manager hosts cluster telemetry, the `ceph` dashboard/modules, PG
# autoscaling, and reports stats. The cluster needs at least one active mgr to
# report HEALTH_OK. We run two (active + standby) so the cluster is never
# without one.
#
# Env: MGR_ID (mgr-a / mgr-b)
# =============================================================================
set -euo pipefail
source /opt/ceph-scripts/lib.sh

# The mgr authenticates to the monitors, so it must wait until they are quorate.
wait_for_bootstrap
wait_for_quorum

DATADIR="/var/lib/ceph/mgr/ceph-${MGR_ID}"
mkdir -p "${DATADIR}"

# Create (or fetch, on restart) this mgr's auth key and drop it in the data dir.
if [[ ! -f "${DATADIR}/keyring" ]]; then
  log "creating auth for mgr.${MGR_ID}"
  ceph auth get-or-create "mgr.${MGR_ID}" \
    mon 'allow profile mgr' osd 'allow *' mds 'allow *' \
    -o "${DATADIR}/keyring"
fi

own_ceph "${DATADIR}"
log "starting ceph-mgr ${MGR_ID}"
exec ceph-mgr -i "${MGR_ID}" -f --setuser ceph --setgroup ceph
