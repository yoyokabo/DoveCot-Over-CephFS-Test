#!/usr/bin/env bash
# =============================================================================
# run-benchmark.sh — the full latency sweep, for both mail formats.
#
# For each format (mdbox, maildir):
#   1. (re)start Dovecot in that format,
#   2. build the message corpus in the bench container,
#   3. sweep imaptest across increasing client counts, recording the
#      per-command latency curve.
#
# Results land in results/<timestamp>/<format>/:
#   sweep.csv            one row per client-count (avg latency per command)
#   clients-<N>.log      full imaptest output for that step
#
# Run from repo root:  ./scripts/run-benchmark.sh
# Env overrides: CLIENTS_SWEEP, SECS, USERS, MSGS, FORMATS
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

DC="docker compose"
CLIENTS_SWEEP="${CLIENTS_SWEEP:-25 50 100 200 400}"
SECS="${SECS:-45}"
USERS="${USERS:-100}"
MSGS="${MSGS:-50}"
FORMATS="${FORMATS:-mdbox maildir}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS="results/${STAMP}"

mkdir -p "${RESULTS}"
echo "==> benchmark run ${STAMP}: formats='${FORMATS}' clients='${CLIENTS_SWEEP}' secs=${SECS}"

wait_dovecot() {
  docker exec bench bash -c 'for i in $(seq 1 180); do (exec 3<>/dev/tcp/dovecot/143) 2>/dev/null && exit 0; sleep 1; done; exit 1' \
    && echo "   dovecot IMAP ready" || { echo "   ERROR: dovecot did not come up"; exit 1; }
}

for fmt in ${FORMATS}; do
  echo "==> format: ${fmt} — (re)starting Dovecot"
  # --force-recreate makes the new MAIL_FORMAT env take effect in a SINGLE
  # clean start (an extra `restart` here would kill the container mid ceph-fuse
  # mount and wedge it).
  MAIL_FORMAT="${fmt}" $DC --profile mail up -d --force-recreate dovecot >/dev/null
  wait_dovecot

  outdir="${RESULTS}/${fmt}"
  mkdir -p "${outdir}"
  # Build the corpus inside the bench container (writes to /tmp in-container).
  docker exec bench /opt/bench/gen-corpus.sh /tmp/corpus.mbox 25

  csv="/results/${STAMP}/${fmt}/sweep.csv"      # path as seen inside bench
  for c in ${CLIENTS_SWEEP}; do
    echo "==> [${fmt}] sweep step: ${c} clients"
    docker exec \
      -e HOST=dovecot -e PORT=143 -e USERS="${USERS}" -e CLIENTS="${c}" \
      -e SECS="${SECS}" -e MSGS="${MSGS}" -e MBOX=/tmp/corpus.mbox \
      -e CSV="${csv}" -e OUT_RAW="/results/${STAMP}/${fmt}/clients-${c}.log" \
      -e TAG="${c}" \
      bench /opt/bench/run-imaptest.sh
  done
  echo "==> [${fmt}] sweep complete. CSV:"
  column -t -s, "${outdir}/sweep.csv" || cat "${outdir}/sweep.csv"
done

echo "==> ALL DONE. Results in ${RESULTS}/"
echo "    Compare formats:  for f in ${FORMATS}; do echo \"== \$f ==\"; column -t -s, ${RESULTS}/\$f/sweep.csv; done"
