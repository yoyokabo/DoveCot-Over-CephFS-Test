#!/usr/bin/env bash
# =============================================================================
# gen-corpus.sh — build the mbox of sample messages imaptest APPENDs from.
#
# Produces a realistic mail size mix: ~80% small (1-20 KB) and ~20% large
# (50 KB - 2 MB). imaptest cycles through these messages when appending, so the
# stored mail has a representative size distribution (which matters for the
# mdbox-vs-maildir contrast: many small files stress metadata, large ones
# stress data I/O).
#
# Usage: gen-corpus.sh [output.mbox] [num_messages]
# =============================================================================
set -euo pipefail
OUT="${1:-/tmp/corpus.mbox}"
N="${2:-25}"

rand_body() {  # $1 = approx size in bytes — emit ~that many bytes of text
  # base64 expands by ~4/3, so feed 3/4 as many urandom bytes. We deliberately
  # avoid a trailing `head -c` truncation: closing the pipe early sends base64
  # a SIGPIPE which, under `set -o pipefail`, would abort the whole script.
  local n=$(( $1 * 3 / 4 + 1 ))
  head -c "${n}" /dev/urandom | base64 | tr -d '\n'
}

: > "${OUT}"
for i in $(seq 1 "${N}"); do
  # 1 in 5 messages is "large", else "small".
  if (( i % 5 == 0 )); then
    size=$(( (RANDOM % 462 + 50) * 1024 ))     # 50 KB .. ~512 KB (large)
  else
    size=$(( (RANDOM % 19 + 1) * 1024 ))       # 1 KB .. 20 KB (small)
  fi
  {
    echo "From sender@bench.local Thu Jan  1 00:00:00 2026"
    echo "From: sender${i}@bench.local"
    echo "To: recipient@bench.local"
    echo "Subject: corpus message ${i} (${size} bytes)"
    echo "Message-ID: <corpus-${i}@bench.local>"
    echo "Date: Thu, 01 Jan 2026 00:00:0${i} +0000"
    echo ""
    rand_body "${size}"
    echo ""
    echo ""
  } >> "${OUT}"
done
echo "[gen-corpus] wrote ${N} messages to ${OUT} ($(wc -c < "${OUT}") bytes)"
