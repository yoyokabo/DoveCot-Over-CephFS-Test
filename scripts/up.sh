#!/usr/bin/env bash
# =============================================================================
# up.sh — bring the whole lab up, in the correct order.
#
# Phase 1: start the Ceph daemons + toolbox and wait for the core to be live.
# Phase 2: apply the rack CRUSH rule, create pools, create CephFS.
# Phase 3: (unless --no-mail) start Dovecot + bench (profile "mail").
#
# Run from the repo root:  ./scripts/up.sh   [--no-mail]
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."          # repo root

DC="docker compose"
WITH_MAIL=1
[[ "${1:-}" == "--no-mail" ]] && WITH_MAIL=0

echo "==> Phase 1: starting Ceph daemons + toolbox"
$DC up -d mon1 mon2 mon3 mgr-a mgr-b osd1 osd2 osd3 osd4 mds-a mds-b toolbox

echo "==> Phase 1: waiting for mon quorum + 4 OSDs in"
$DC exec -T toolbox /opt/scripts/wait-healthy.sh 300

echo "==> Phase 2: applying rack CRUSH rule"
$DC exec -T toolbox /opt/ceph-scripts/apply-crush.sh

echo "==> Phase 2: creating pools"
$DC exec -T toolbox /opt/scripts/create-pools.sh

echo "==> Phase 2: creating CephFS"
$DC exec -T toolbox /opt/scripts/create-fs.sh

echo "==> Cluster status:"
$DC exec -T toolbox ceph -s
$DC exec -T toolbox ceph osd tree

if [[ "${WITH_MAIL}" == "1" ]]; then
  echo "==> Phase 3: starting Dovecot + bench (profile mail)"
  $DC --profile mail up -d --build dovecot bench
  echo "==> Done. Dovecot + bench are up."
else
  echo "==> Done (core only; rerun without --no-mail to start Dovecot + bench)."
fi
