#!/usr/bin/env bash
# =============================================================================
# down.sh — tear the lab down.
#
#   ./scripts/down.sh          stop + remove containers (KEEP data volumes)
#   ./scripts/down.sh --wipe   also delete all volumes (fresh cluster next time)
#
# Because OSDs are file-backed BlueStore inside their data volumes, there are no
# host loop devices to clean up — removing the volumes is enough for a reset.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

DC="docker compose"

if [[ "${1:-}" == "--wipe" ]]; then
  echo "==> stopping and removing containers + volumes (full reset)"
  $DC --profile mail down -v --remove-orphans
  # OSD data lives in host RAM under /dev/shm (bind-mounted). The files are
  # owned by the in-container 'ceph' user (uid 167), so a plain host `rm` hits
  # permission denied — remove them from inside a throwaway root container that
  # has /dev/shm mounted.
  echo "==> clearing RAM-backed OSD data in /dev/shm/ceph-osd*"
  CEPH_IMAGE="$(grep -E '^CEPH_IMAGE=' .env | cut -d= -f2)"
  docker run --rm -v /dev/shm:/hostshm "${CEPH_IMAGE:-quay.io/ceph/ceph:v18}" \
    rm -rf /hostshm/ceph-osd1 /hostshm/ceph-osd2 /hostshm/ceph-osd3 /hostshm/ceph-osd4 \
    2>/dev/null || true
else
  echo "==> stopping and removing containers (keeping data volumes)"
  $DC --profile mail down --remove-orphans
fi
echo "==> done."
