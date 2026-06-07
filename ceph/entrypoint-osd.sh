#!/usr/bin/env bash
# =============================================================================
# entrypoint-osd.sh — runs a Ceph OSD (Object Storage Daemon).
#
# Each OSD stores actual object data. We run FOUR, one per container, and pin
# each into a distinct CRUSH "rack" via --crush-location. With pools at size=3
# and failure domain = rack, every object's 3 replicas land in 3 different
# racks, leaving the 4th rack as spare capacity so a single OSD/rack loss can
# self-heal.
#
# Storage: file-backed BlueStore (the "vstart" trick) — the OSD's `block`
# device is just a sparse file inside the container's data volume. This avoids
# needing real block devices or loop devices, and survives container restarts
# (the data volume persists), which is essential for the OSD-down chaos test.
#
# Env: OSD_RACK (1..4)  -> this OSD's rack number, used for both CRUSH location
#                          and a stable host bucket name (osd1..osd4).
# =============================================================================
set -euo pipefail
source /opt/ceph-scripts/lib.sh

# OSDs register themselves with the monitors and read the admin keyring, so
# wait until the cluster is bootstrapped and quorate.
wait_for_bootstrap
wait_for_quorum

OSD_ROOT=/var/lib/ceph/osd
MARKER="${OSD_ROOT}/.osd_id"          # remembers our OSD id across restarts
CRUSH_LOC="root=default rack=rack${OSD_RACK} host=osd${OSD_RACK}"

mkdir -p "${OSD_ROOT}"

if [[ -f "${MARKER}" ]]; then
  # ---- Restart path: OSD already exists, just bring it back up -------------
  OSD_ID="$(cat "${MARKER}")"
  log "reusing existing osd.${OSD_ID} (rack${OSD_RACK})"
else
  # ---- First boot: create the OSD following Ceph's manual-OSD procedure ----
  log "creating new OSD in rack${OSD_RACK}"
  OSD_UUID="$(uuidgen)"
  OSD_SECRET="$(ceph-authtool --gen-print-key)"
  # `ceph osd new` allocates the numeric OSD id and registers its cephx secret.
  OSD_ID="$(echo "{\"cephx_secret\": \"${OSD_SECRET}\"}" \
            | ceph osd new "${OSD_UUID}" -i - -n client.admin)"
  log "allocated osd.${OSD_ID}"

  DATADIR="${OSD_ROOT}/ceph-${OSD_ID}"
  mkdir -p "${DATADIR}"
  # The BlueStore "block" device: a sparse file of OSD_SIZE_GB.
  truncate -s "${OSD_SIZE_GB}G" "${DATADIR}/block"
  # Local OSD keyring matching the secret we just registered.
  ceph-authtool --create-keyring "${DATADIR}/keyring" \
    --name "osd.${OSD_ID}" --add-key "${OSD_SECRET}"
  # Format the BlueStore filesystem onto the block file.
  ceph-osd -i "${OSD_ID}" --mkfs --osd-uuid "${OSD_UUID}"
  echo "${OSD_ID}" > "${MARKER}"
fi

DATADIR="${OSD_ROOT}/ceph-${OSD_ID}"
own_ceph "${DATADIR}"
log "starting ceph-osd ${OSD_ID} at CRUSH location: ${CRUSH_LOC}"
# osd_crush_update_on_start=true (set in ceph.conf) makes the OSD create/move
# itself to this rack+host on every start, which also auto-creates the rack
# buckets in the CRUSH map.
exec ceph-osd -i "${OSD_ID}" -f --setuser ceph --setgroup ceph \
  --crush-location "${CRUSH_LOC}"
