#!/usr/bin/env bash
# =============================================================================
# create-fs.sh — create the CephFS filesystem and wait for it to go active.
#
# `ceph fs new` binds the metadata + data pools into a named filesystem. Once
# created, one of our two idle MDS daemons is promoted to "active" and the
# other becomes "standby" (our failover spare). The Dovecot container then
# mounts this filesystem with ceph-fuse.
# =============================================================================
set -euo pipefail

FS_NAME="${CEPHFS_NAME:-cephfs}"
META_POOL="cephfs_metadata"
DATA_POOL="cephfs_data"

if ceph fs ls | grep -q "name: ${FS_NAME},"; then
  echo "[create-fs] filesystem ${FS_NAME} already exists."
else
  echo "[create-fs] creating filesystem ${FS_NAME}"
  ceph fs new "${FS_NAME}" "${META_POOL}" "${DATA_POOL}"
fi

# Tag the pools with the 'cephfs' application (clears POOL_APP_NOT_ENABLED) and
# enable msgr2 on the mons if it isn't already (clears MON_MSGR2_NOT_ENABLED).
# Both are idempotent and keep a fresh cluster at clean HEALTH_OK.
ceph osd pool application enable "${DATA_POOL}" cephfs 2>/dev/null || true
ceph osd pool application enable "${META_POOL}" cephfs 2>/dev/null || true
ceph mon enable-msgr2 2>/dev/null || true

# Keep exactly 1 active MDS; the second daemon becomes a hot standby. This is
# the configuration the MDS-failover chaos test exercises.
ceph fs set "${FS_NAME}" max_mds 1
ceph fs set "${FS_NAME}" standby_count_wanted 1

echo "[create-fs] waiting for an MDS to become active..."
until ceph fs status "${FS_NAME}" 2>/dev/null | grep -q "active"; do
  sleep 2
done

echo "[create-fs] filesystem status:"
ceph fs status "${FS_NAME}"
echo "[create-fs] done."
