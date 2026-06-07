#!/usr/bin/env bash
# =============================================================================
# lib.sh — shared helpers sourced by every Ceph daemon entrypoint.
#
# This file is bind-mounted read-only into each Ceph container at
# /opt/ceph-scripts/lib.sh (see docker-compose.yml). It centralises the few
# things every daemon needs: locating config, waiting for the cluster to come
# up, and generating the initial ceph.conf + keyrings exactly once.
# =============================================================================
set -euo pipefail

# Where the SHARED cluster config + admin/mon keyrings live. This directory is
# a docker volume mounted on EVERY daemon, so once the primary mon writes the
# fsid/keyrings/monmap here, all other daemons can read them. It is the single
# rendezvous point for the hand-rolled bootstrap.
export CEPH_CONF_DIR=/etc/ceph
export CEPH_CONF="${CEPH_CONF_DIR}/ceph.conf"
export MON_KEYRING="${CEPH_CONF_DIR}/ceph.mon.keyring"
export ADMIN_KEYRING="${CEPH_CONF_DIR}/ceph.client.admin.keyring"
export MONMAP="${CEPH_CONF_DIR}/monmap"
export BOOTSTRAP_DONE="${CEPH_CONF_DIR}/.bootstrap-done"

log() { echo "[$(date +%H:%M:%S)] [$(hostname)] $*"; }

# Ceph daemons drop privileges to the 'ceph' user; their data dirs must be
# owned by it. Call this on a data dir right before launching the daemon.
own_ceph() { chown -R ceph:ceph "$1"; }

# Block until the SHARED bootstrap artifacts exist. Secondary mons, mgrs, osds
# and mds all call this so they never race ahead of the primary mon.
wait_for_bootstrap() {
  log "waiting for primary mon to publish cluster config..."
  until [[ -f "${BOOTSTRAP_DONE}" && -f "${CEPH_CONF}" && -f "${ADMIN_KEYRING}" ]]; do
    sleep 2
  done
  log "bootstrap config present."
}

# Block until the monitor cluster has formed quorum and answers `ceph -s`.
# `ceph -s` only succeeds once a MAJORITY of the 3 monitors are up, so any
# daemon that waits on this is guaranteed to talk to a live, quorate cluster.
wait_for_quorum() {
  log "waiting for monitor quorum..."
  until ceph -s >/dev/null 2>&1; do
    sleep 2
  done
  log "monitor quorum reached."
}

# -----------------------------------------------------------------------------
# bootstrap_cluster — run ONCE, by the primary monitor only.
# Generates: ceph.conf, the mon. keyring, the client.admin keyring, the
# bootstrap-osd keyring, and the initial monmap listing all three monitors by
# static IP. Idempotent: if ceph.conf already exists it does nothing.
# -----------------------------------------------------------------------------
bootstrap_cluster() {
  if [[ -f "${CEPH_CONF}" ]]; then
    log "cluster already bootstrapped; skipping."
    return 0
  fi
  log "bootstrapping new cluster (fsid=${CEPH_FSID})"

  # 1. ceph.conf — the minimal cluster description every daemon reads.
  cat > "${CEPH_CONF}" <<EOF
[global]
    fsid = ${CEPH_FSID}
    # The three monitors, addressed by their fixed docker IPs. Clients and
    # daemons contact any of these to learn the rest of the cluster map.
    mon_initial_members = mon1, mon2, mon3
    mon_host = ${MON1_IP}, ${MON2_IP}, ${MON3_IP}
    public_network = ${CEPH_PUBLIC_SUBNET}
    cluster_network = ${CEPH_PUBLIC_SUBNET}

    # Authentication: cephx everywhere (the Ceph default; keyrings handle it).
    auth_cluster_required = cephx
    auth_service_required = cephx
    auth_client_required = cephx

    # --- Small-cluster tuning (4 OSDs, lab) ---------------------------------
    # Default pool replica size and the failure domain for new pools.
    osd_pool_default_size = ${POOL_SIZE}
    osd_pool_default_min_size = ${POOL_MIN_SIZE}
    # Let OSDs place themselves into CRUSH using their --crush-location on boot.
    osd_crush_update_on_start = true
    # 4 OSDs is below Ceph's default health thresholds; relax them so a healthy
    # lab cluster reports HEALTH_OK instead of nagging warnings.
    mon_max_pg_per_osd = 400
    mon_allow_pool_delete = true
    # Speed up failure detection a little so chaos tests react promptly.
    osd_heartbeat_grace = 20

[mon]
    # Allow the cluster to keep serving with a single mon down (2/3 quorum).
    mon_warn_on_insecure_global_id_reclaim = false
    mon_warn_on_insecure_global_id_reclaim_allowed = false
    # The mon data dirs sit on the host disk, which in this lab is ~86% full.
    # Lower the "low on available space" warning threshold so a healthy lab
    # cluster reports HEALTH_OK. (Raise/remove this on a real deployment.)
    mon_data_avail_warn = 5
EOF

  # 2. mon. keyring — the shared secret monitors use to talk to each other.
  ceph-authtool --create-keyring "${MON_KEYRING}" \
    --gen-key -n mon. --cap mon 'allow *'

  # 3. client.admin keyring — full-control admin user used by the CLI/scripts.
  ceph-authtool --create-keyring "${ADMIN_KEYRING}" \
    --gen-key -n client.admin \
    --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *' --cap mgr 'allow *'

  # 4. bootstrap-osd keyring — lets OSD containers create their own auth.
  ceph-authtool --create-keyring "${CEPH_CONF_DIR}/ceph.keyring" \
    --gen-key -n client.bootstrap-osd --cap mon 'profile bootstrap-osd' 2>/dev/null || true

  # Fold admin into the mon keyring so the monitor knows about the admin user.
  ceph-authtool "${MON_KEYRING}" --import-keyring "${ADMIN_KEYRING}"

  # 5. monmap — the initial membership: all three mons, by name + IP.
  monmaptool --create \
    --add mon1 "${MON1_IP}" \
    --add mon2 "${MON2_IP}" \
    --add mon3 "${MON3_IP}" \
    --fsid "${CEPH_FSID}" "${MONMAP}"

  chmod 644 "${ADMIN_KEYRING}" "${CEPH_CONF}"
  log "cluster bootstrap artifacts written to ${CEPH_CONF_DIR}"
}

# mkfs a monitor's data store from the shared monmap + mon keyring. Safe to
# call repeatedly: skips if this mon's store already exists (so restarts during
# chaos tests reuse the existing data instead of wiping it).
mkfs_mon() {
  # NOTE: split declarations — a single `local a=.. b=${a}` expands b BEFORE a
  # is assigned, which trips `set -u` (unbound variable).
  local id="$1"
  local datadir="/var/lib/ceph/mon/ceph-${id}"
  if [[ -f "${datadir}/keyring" ]]; then
    log "mon.${id} store already exists; reusing."
    return 0
  fi
  mkdir -p "${datadir}"
  log "mkfs mon.${id}"
  ceph-mon --mkfs -i "${id}" --monmap "${MONMAP}" --keyring "${MON_KEYRING}"
  own_ceph "${datadir}"
}
