#!/usr/bin/env bash
# =============================================================================
# run-imaptest.sh — one imaptest run, with latency parsing.
#
# Runs imaptest against Dovecot at a single client-count, captures the raw
# output, and extracts the per-command average latency (imaptest's "ms/cmd avg"
# lines) into a one-line CSV record. Used by both the sweep (run-all.sh) and
# the chaos timeline (measure-recovery.sh).
#
# Env / args:
#   HOST (dovecot) PORT (143) USERS (100) CLIENTS (50) SECS (60)
#   MBOX (/tmp/corpus.mbox) MSGS (50) BOX (INBOX)
#   OUT_RAW  : path to write full imaptest output (optional)
#   CSV      : path to append the parsed CSV row (optional)
#   TAG      : label written as the first CSV column (default = CLIENTS)
#
# imaptest "ms/cmd avg" columns (fixed order):
#   Logi List Stat Sele Fetc Fet2 Stor Dele Expu Appe Logo
# =============================================================================
set -euo pipefail

HOST="${HOST:-dovecot}"; PORT="${PORT:-143}"
USERS="${USERS:-100}";   CLIENTS="${CLIENTS:-50}"
SECS="${SECS:-60}";      MBOX="${MBOX:-/tmp/corpus.mbox}"
MSGS="${MSGS:-50}";      BOX="${BOX:-INBOX}"
PASS="${PASS:-pass}";    USERFMT="${USERFMT:-user%04d}"
OUT_RAW="${OUT_RAW:-}";  CSV="${CSV:-}"; TAG="${TAG:-${CLIENTS}}"

raw="$(mktemp)"
echo "[run-imaptest] clients=${CLIENTS} users=${USERS} secs=${SECS} box=${BOX} -> host=${HOST}"
# secs= makes imaptest exit after the run. msgs= is the target mailbox size
# (imaptest grows mailboxes toward it, which is our in-line seeding).
imaptest host="${HOST}" port="${PORT}" \
         user="${USERFMT}" users="${USERS}" pass="${PASS}" \
         mbox="${MBOX}" clients="${CLIENTS}" msgs="${MSGS}" \
         box="${BOX}" secs="${SECS}" 2>&1 | tee "${raw}" >/dev/null || true

[[ -n "${OUT_RAW}" ]] && cp "${raw}" "${OUT_RAW}"

# Average each command's latency across all "ms/cmd avg" lines in the run
# (steady-state mean). awk emits: tag,logi,list,stat,sele,fetc,fet2,stor,dele,expu,appe,logo,samples
# A "ms/cmd avg" value of 0 means NO command of that type completed in that
# interval (e.g. early cold-start blocks), not "0 ms latency". Averaging those
# zeros in would understate latency, so we average only the non-zero samples
# per column. The "samples" column reports how many intervals contributed to
# the busiest command (a low count => noisy/short run).
row="$(awk -v tag="${TAG}" '
  /ms\/cmd avg/ {
    for (i=1;i<=11;i++){ if($i+0>0){ sum[i]+=$i; cnt[i]++ } }
    blocks++
  }
  END {
    if(blocks==0){ printf "%s,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,0\n", tag; exit }
    printf "%s", tag
    maxc=0
    for(i=1;i<=11;i++){
      if(cnt[i]>0){ printf ",%.1f", sum[i]/cnt[i]; if(cnt[i]>maxc)maxc=cnt[i] }
      else        { printf ",0.0" }
    }
    printf ",%d\n", maxc
  }' "${raw}")"

echo "[run-imaptest] avg latency row: ${row}"
if [[ -n "${CSV}" ]]; then
  # Write a header once.
  if [[ ! -s "${CSV}" ]]; then
    echo "tag,logi_ms,list_ms,stat_ms,sele_ms,fetc_ms,fet2_ms,stor_ms,dele_ms,expu_ms,appe_ms,logo_ms,samples" > "${CSV}"
  fi
  echo "${row}" >> "${CSV}"
fi
rm -f "${raw}"
