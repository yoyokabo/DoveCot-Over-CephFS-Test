#!/usr/bin/env bash
# =============================================================================
# create-pools.sh — create the two CephFS pools on the rack-aware rule.
#
# CephFS needs two RADOS pools:
#   - cephfs_metadata : the directory tree / inodes (small, latency-critical;
#                       this is what the MDS reads/writes constantly)
#   - cephfs_data     : the actual file contents (mail messages)
#
# Both are replicated size=3 using the `rack_replicated` rule, so every replica
# sits in a different rack. Env POOL_SIZE / POOL_MIN_SIZE / pool names come from
# .env (exported into the toolbox container).
# =============================================================================
set -euo pipefail

RULE_NAME="rack_replicated"
META_POOL="cephfs_metadata"
DATA_POOL="cephfs_data"
# Small fixed PG counts for a 4-OSD lab; the PG autoscaler will adjust as
# needed. Metadata pool stays small; data pool a bit larger.
META_PG=16
DATA_PG=32

create_pool() {
  local name="$1" pg="$2"
  if ceph osd pool ls | grep -qx "${name}"; then
    echo "[create-pools] pool ${name} exists; ensuring rule/size."
  else
    echo "[create-pools] creating pool ${name} (pg=${pg}, rule=${RULE_NAME})"
    ceph osd pool create "${name}" "${pg}" "${pg}" replicated "${RULE_NAME}"
  fi
  # Enforce replica size + the rack rule regardless of prior state.
  ceph osd pool set "${name}" crush_rule "${RULE_NAME}"
  ceph osd pool set "${name}" size "${POOL_SIZE:-3}"
  ceph osd pool set "${name}" min_size "${POOL_MIN_SIZE:-2}"
}

create_pool "${META_POOL}" "${META_PG}"
create_pool "${DATA_POOL}" "${DATA_PG}"

echo "[create-pools] pool detail:"
ceph osd pool ls detail
echo "[create-pools] done."
