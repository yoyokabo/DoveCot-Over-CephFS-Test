#!/usr/bin/env bash
# =============================================================================
# measure-recovery.sh — shared helpers for the failure/recovery experiments.
#
# Source this from a scenario script (osd-down.sh, mon-failover.sh, ...). It
# runs on the HOST and provides the common machinery:
#
#   * chaos_init <name>            set up an output dir under results/chaos/
#   * chaos_start_load [clients]   launch imaptest under continuous load,
#                                   logging each line with a wall-clock epoch
#   * chaos_mark <label>           record a timestamped EVENT (e.g. fault in)
#   * chaos_wait_pgs_clean [to]    block until all PGs are active+clean
#   * chaos_wait_health_ok [to]    block until ceph health == HEALTH_OK
#   * chaos_settle [secs]          let load keep running to capture recovery
#   * chaos_finish                 stop load + health sampler, print summary
#
# The result is a timeline: imaptest.log (timestamped client latency), an
# events.log (fault injected / recovered, with epochs), and health.log (cluster
# health sampled every 2s) — all sharing the same clock so you can line up the
# client-visible impact against the cluster's recovery.
# =============================================================================
set -euo pipefail

# --- config (overridable via env) -------------------------------------------
CHAOS_CLIENTS="${CHAOS_CLIENTS:-100}"   # representative mid-load point
CHAOS_USERS="${CHAOS_USERS:-100}"
CHAOS_BASELINE="${CHAOS_BASELINE:-20}"  # seconds of steady-state before fault
CHAOS_DURATION="${CHAOS_DURATION:-240}" # total imaptest run length (s)
CHAOS_MBOX="${CHAOS_MBOX:-/tmp/corpus.mbox}"

# toolbox = ceph CLI; runs queries. -T disables TTY for scripting.
ceph_q() { docker compose exec -T toolbox ceph "$@" 2>/dev/null; }

now() { date +%s; }

chaos_init() {
  CHAOS_NAME="$1"
  CHAOS_STAMP="$(date +%Y%m%d-%H%M%S)"
  CHAOS_DIR="results/chaos/${CHAOS_STAMP}-${CHAOS_NAME}"
  mkdir -p "${CHAOS_DIR}"
  CHAOS_EVENTS="${CHAOS_DIR}/events.log"
  CHAOS_HEALTH="${CHAOS_DIR}/health.log"
  CHAOS_IMAP="${CHAOS_DIR}/imaptest.log"
  : > "${CHAOS_EVENTS}"; : > "${CHAOS_HEALTH}"; : > "${CHAOS_IMAP}"
  echo "==> [${CHAOS_NAME}] results -> ${CHAOS_DIR}"
  # Safety net: no matter how we exit (timeout, error, Ctrl-C), stop background
  # load/sampler and make sure every Ceph daemon is running again so we never
  # leave the cluster crippled.
  trap chaos_cleanup EXIT
  chaos_mark "START ${CHAOS_NAME} (clients=${CHAOS_CLIENTS})"
}

chaos_cleanup() {
  [[ -n "${CHAOS_SAMPLER_PID:-}" ]] && kill "${CHAOS_SAMPLER_PID}" 2>/dev/null || true
  [[ -n "${CHAOS_LOAD_PID:-}" ]] && kill "${CHAOS_LOAD_PID}" 2>/dev/null || true
  docker exec bench pkill -9 imaptest 2>/dev/null || true
  # Restart any daemon a scenario may have stopped (idempotent for running ones).
  docker compose start mon1 mon2 mon3 mgr-a mgr-b osd1 osd2 osd3 osd4 mds-a mds-b \
    >/dev/null 2>&1 || true
}

chaos_mark() {  # record an event on the shared clock
  local epoch; epoch="$(now)"
  echo "${epoch} $(date -d "@${epoch}" '+%H:%M:%S') $*" | tee -a "${CHAOS_EVENTS}"
}

# Background sampler: cluster health string every 2s, epoch-stamped.
_chaos_health_sampler() {
  while true; do
    echo "$(now) $(docker compose exec -T toolbox ceph health 2>/dev/null | tr '\n' ' ')" >> "${CHAOS_HEALTH}"
    sleep 2
  done
}

# Launch imaptest in the background; prefix every output line with an epoch so
# the latency timeline aligns with events.log / health.log.
chaos_start_load() {
  local clients="${1:-${CHAOS_CLIENTS}}"
  chaos_mark "LOAD START imaptest clients=${clients} for ${CHAOS_DURATION}s"
  ( docker exec -e HOST=dovecot -e PORT=143 -e USERS="${CHAOS_USERS}" \
        -e CLIENTS="${clients}" -e SECS="${CHAOS_DURATION}" -e MSGS=50 \
        -e MBOX="${CHAOS_MBOX}" -e TAG="${CHAOS_NAME}" \
        bench imaptest host=dovecot port=143 user=user%04d users="${CHAOS_USERS}" \
        pass=pass mbox="${CHAOS_MBOX}" clients="${clients}" msgs=50 secs="${CHAOS_DURATION}" 2>&1 \
    | while IFS= read -r line; do printf '%s %s\n' "$(now)" "${line}"; done \
    >> "${CHAOS_IMAP}" ) &
  CHAOS_LOAD_PID=$!
  _chaos_health_sampler & CHAOS_SAMPLER_PID=$!
  echo "   load pid=${CHAOS_LOAD_PID}, health sampler pid=${CHAOS_SAMPLER_PID}"
  echo "   warming up ${CHAOS_BASELINE}s of baseline..."
  sleep "${CHAOS_BASELINE}"
}

# True while any PG is NOT active+clean (degraded/backfilling/peering/...).
_pgs_dirty() {
  local s; s="$(ceph_q pg stat)"
  echo "${s}" | grep -qE 'degraded|undersized|backfill|recover|peering|stale|remapped|inactive|incomplete'
}

chaos_wait_pgs_clean() {  # recovery == data fully re-replicated (PGs clean)
  local timeout="${1:-180}" start; start="$(now)"
  echo "   waiting for all PGs active+clean (timeout ${timeout}s)..."
  while _pgs_dirty; do
    if (( $(now) - start > timeout )); then chaos_mark "TIMEOUT waiting PGs clean"; return 0; fi
    sleep 2
  done
  chaos_mark "RECOVERED PGs active+clean ($(ceph_q pg stat | head -1))"
}

chaos_wait_health_ok() {
  local timeout="${1:-180}" start; start="$(now)"
  echo "   waiting for HEALTH_OK (timeout ${timeout}s)..."
  while [[ "$(ceph_q health | tr -d '[:space:]')" != "HEALTH_OK" ]]; do
    if (( $(now) - start > timeout )); then chaos_mark "TIMEOUT waiting HEALTH_OK ($(ceph_q health))"; return 0; fi
    sleep 2
  done
  chaos_mark "RECOVERED HEALTH_OK"
}

# Wait until the cluster answers at all (used by quorum-loss recovery).
chaos_wait_responsive() {
  local timeout="${1:-120}" start; start="$(now)"
  echo "   waiting for mons to answer (timeout ${timeout}s)..."
  until ceph_q -s >/dev/null 2>&1; do
    if (( $(now) - start > timeout )); then chaos_mark "TIMEOUT waiting responsive"; return 0; fi
    sleep 2
  done
  chaos_mark "RECOVERED mons responsive"
}

chaos_settle() { local s="${1:-20}"; echo "   settling ${s}s under load..."; sleep "${s}"; }

chaos_finish() {
  chaos_mark "STOP"
  kill "${CHAOS_SAMPLER_PID}" 2>/dev/null || true
  # Let imaptest finish on its own (secs=) or stop it.
  wait "${CHAOS_LOAD_PID}" 2>/dev/null || true
  echo "==> [${CHAOS_NAME}] done. Artifacts:"
  ls -1 "${CHAOS_DIR}"
  echo "----- events.log -----"; cat "${CHAOS_EVENTS}"
  echo "----- latency around the fault (imaptest 'ms/cmd avg' lines, epoch-stamped) -----"
  grep "ms/cmd avg" "${CHAOS_IMAP}" || echo "(none captured)"
}
