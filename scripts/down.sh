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
else
  echo "==> stopping and removing containers (keeping data volumes)"
  $DC --profile mail down --remove-orphans
fi
echo "==> done."
