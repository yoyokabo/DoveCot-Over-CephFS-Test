#!/usr/bin/env bash
# =============================================================================
# wait-healthy.sh — block until the cluster is usable.
#
# Run from the toolbox. "Usable" here means: monitors quorate AND all 4 OSDs
# up+in. We deliberately accept HEALTH_WARN (a fresh cluster warns about things
# like "no pools" or PG autoscale) — we only insist the core daemons are live.
# A stricter HEALTH_OK wait happens after pools/fs exist.
# =============================================================================
set -euo pipefail
TIMEOUT="${1:-300}"   # seconds
start=$(date +%s)

echo "[wait-healthy] waiting for mon quorum + 4 OSDs up/in (timeout ${TIMEOUT}s)..."
while true; do
  if ceph -s >/dev/null 2>&1; then
    up="$(ceph osd stat -f json 2>/dev/null | grep -o '"num_up_osds":[0-9]*' | grep -o '[0-9]*' || echo 0)"
    in="$(ceph osd stat -f json 2>/dev/null | grep -o '"num_in_osds":[0-9]*' | grep -o '[0-9]*' || echo 0)"
    if [[ "${up}" == "4" && "${in}" == "4" ]]; then
      echo "[wait-healthy] cluster up: 4/4 OSDs in. Status:"
      ceph -s
      exit 0
    fi
    echo "[wait-healthy] mons up; OSDs up=${up} in=${in} ..."
  else
    echo "[wait-healthy] waiting for mon quorum ..."
  fi
  if (( $(date +%s) - start > TIMEOUT )); then
    echo "[wait-healthy] TIMEOUT after ${TIMEOUT}s. Last status:" >&2
    ceph -s || true
    exit 1
  fi
  sleep 3
done
