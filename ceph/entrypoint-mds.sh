#!/usr/bin/env bash
# =============================================================================
# entrypoint-mds.sh — runs a Ceph METADATA SERVER (ceph-mds).
#
# The MDS serves CephFS metadata (the directory tree, inodes, locks). It is the
# component that POSIX mail formats hammer — maildir especially, with its
# create/rename/unlink per message. We run TWO (active + standby) so killing
# the active one triggers a standby takeover (the MDS-failover chaos test).
#
# The MDS daemon starts up "available" but stays idle until a filesystem is
# created with `ceph fs new` (see scripts/create-fs.sh).
#
# Env: MDS_ID (mds-a / mds-b)
# =============================================================================
set -euo pipefail
source /opt/ceph-scripts/lib.sh

wait_for_bootstrap
wait_for_quorum

DATADIR="/var/lib/ceph/mds/ceph-${MDS_ID}"
mkdir -p "${DATADIR}"

if [[ ! -f "${DATADIR}/keyring" ]]; then
  log "creating auth for mds.${MDS_ID}"
  ceph auth get-or-create "mds.${MDS_ID}" \
    mon 'allow profile mds' osd 'allow rwx' mds 'allow' mgr 'allow profile mds' \
    -o "${DATADIR}/keyring"
fi

own_ceph "${DATADIR}"
log "starting ceph-mds ${MDS_ID}"
exec ceph-mds -i "${MDS_ID}" -f --setuser ceph --setgroup ceph
