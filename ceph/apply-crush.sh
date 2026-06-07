#!/usr/bin/env bash
# =============================================================================
# apply-crush.sh — define the rack-aware replication rule.
#
# Run once, after all OSDs are up, from the toolbox container.
#
# Each OSD already placed itself into a CRUSH "rack" bucket on boot (via its
# --crush-location), so the CRUSH tree looks like:
#     default
#       ├── rack1 → host osd1 → osd.0
#       ├── rack2 → host osd2 → osd.1
#       ├── rack3 → host osd3 → osd.2
#       └── rack4 → host osd4 → osd.3
#
# What's missing is a replication RULE that spreads replicas across racks. The
# stock `replicated_rule` uses failure domain = host, which on this tree would
# happily put all copies in one rack. We create `rack_replicated` with
# `chooseleaf ... type rack` so the 3 replicas are forced into 3 distinct
# racks — the whole point of the experiment.
# =============================================================================
set -euo pipefail

RULE_NAME="rack_replicated"

echo "[apply-crush] waiting for all 4 OSDs to be up and in..."
# `ceph osd ls` lists OSD ids; wait until we have 4 and none are down.
until [[ "$(ceph osd ls 2>/dev/null | wc -l)" -ge 4 ]] \
      && [[ "$(ceph osd stat -f json 2>/dev/null | grep -o '"num_up_osds":[0-9]*' | grep -o '[0-9]*')" == "4" ]]; do
  sleep 2
done

echo "[apply-crush] current CRUSH tree:"
ceph osd tree

# Create the rack-failure-domain rule (idempotent).
if ceph osd crush rule ls | grep -qx "${RULE_NAME}"; then
  echo "[apply-crush] rule ${RULE_NAME} already exists."
else
  echo "[apply-crush] creating replicated rule ${RULE_NAME} (failure domain = rack)"
  # args: <name> <root> <failure-domain-type> [device-class]
  ceph osd crush rule create-replicated "${RULE_NAME}" default rack
fi

echo "[apply-crush] CRUSH rules:"
ceph osd crush rule ls

# --- recovery tuning --------------------------------------------------------
# By default a DOWN OSD is kept "in" for 600s (mon_osd_down_out_interval) before
# Ceph marks it out and re-replicates. For the OSD-down chaos test we want to
# observe AUTOMATIC self-heal quickly, so shorten it to 30s. (On a real cluster
# you'd keep this high to avoid needless backfill on brief blips.)
ceph config set mon mon_osd_down_out_interval 30
echo "[apply-crush] mon_osd_down_out_interval set to 30s (fast self-heal demo)"

# CRITICAL for this topology: with 1 OSD per rack, losing an OSD == losing a
# whole RACK. Ceph's default mon_osd_down_out_subtree_limit=rack would then
# REFUSE to auto-mark-out the OSD (it assumes a rack outage is temporary and
# avoids massive rebalancing), so no self-heal. We raise the limit to 'root' so
# a rack(=host=osd) failure IS auto-outed and re-replicated onto the spare rack.
ceph config set mon mon_osd_down_out_subtree_limit root
echo "[apply-crush] mon_osd_down_out_subtree_limit set to root (enable rack self-heal)"
echo "[apply-crush] done."
