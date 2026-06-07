# Reading the results

All output lands under `results/` (gitignored). Two kinds:

## 1. Latency sweep — `results/<timestamp>/<format>/`

Produced by `scripts/run-benchmark.sh`.

- **`sweep.csv`** — one row per client-count:

  ```
  tag,logi_ms,list_ms,stat_ms,sele_ms,fetc_ms,fet2_ms,stor_ms,dele_ms,expu_ms,appe_ms,logo_ms,samples
  25,5.5,113.0,110.5,104.5,103.5,99.5,127.0,147.5,136.5,277.5,0.0,2
  50,6.5,168.0,136.0,123.0,194.5,181.0,236.0,319.5,261.5,488.5,0.0,2
  ...
  ```

  Each value is the average **ms per command** (from imaptest's `ms/cmd avg`
  lines, non-zero samples only) at that client count. Columns are the IMAP
  commands: **Logi**n, **List**, **Stat**us, **Sele**ct, **Fetc**h, **Fet2**
  (a second fetch profile), **Stor**e, **Dele**te, **Expu**nge, **Appe**nd,
  **Logo**ut. `samples` = how many measurement intervals contributed (low ⇒
  noisy / short run).

- **`clients-<N>.log`** — full raw imaptest output for that step (per-second
  command rates + stall warnings).

**How to read it.** Latency should stay roughly flat at low client counts, then
climb sharply past the **knee** — that's the point where CephFS/Dovecot
saturates. `appe_ms` (APPEND) is usually highest: it writes a message + updates
indexes + fsyncs, each replicated 3×. Compare the two formats:

```bash
for f in mdbox maildir; do echo "== $f =="; column -t -s, results/<ts>/$f/sweep.csv; done
```

Expect **maildir** to show heavier metadata-command cost (List/Status/Select/
Append create/stat many small files → more MDS traffic) and **mdbox** to be
lighter on metadata but do more work per packed file. That contrast is the core
"is CephFS good for Dovecot, and in which format" finding.

## 2. Failure timeline — `results/chaos/<timestamp>-<scenario>/`

Produced by the `chaos/*.sh` scripts. Three files share one epoch clock:

- **`events.log`** — the script's markers, e.g.:
  ```
  1780855973 21:12:53 INJECT  docker compose stop osd2 ...
  1780856010 21:13:30 RECOVERED PGs active+clean (...)
  1780856012 21:13:32 RESTORE docker compose start osd2
  1780856040 21:14:00 RECOVERED HEALTH_OK
  ```
  Subtract epochs to get **recovery time** (here self-heal ≈ 37s after the OSD
  was stopped: 30s down-out + ~7s backfill).

- **`health.log`** — `ceph health` sampled every 2s (epoch-stamped). Watch the
  transitions: `HEALTH_OK` → `HEALTH_WARN … degraded … N pgs undersized` →
  (backfill) → `HEALTH_OK`.

- **`imaptest.log`** — every imaptest output line, epoch-stamped. Grep the
  `ms/cmd avg` lines and line their epochs up against the INJECT/RECOVERED
  markers to see the **client-visible** impact: latency baseline → spike at the
  fault → degraded plateau → return to baseline.

  ```bash
  d=results/chaos/<ts>-osd-down-osd2
  grep 'ms/cmd avg' "$d/imaptest.log"      # latency timeline (epoch-stamped)
  cat "$d/events.log"                      # when the fault hit / recovered
  ```

### What each scenario should show

- **osd-down**: cluster stays *available* throughout (load keeps completing,
  maybe a brief bump); `health.log` goes degraded then self-heals back to
  `HEALTH_OK` once the lost copies are rebuilt on rack4; recovery time ≈
  `mon_osd_down_out_interval` (30s) + backfill.
- **mon-failover (1/3)**: barely a blip — quorum survives; `events.log` shows the
  cluster responsive again within a second or two.
- **mon-quorumloss (2/3)**: a real **stall** — `ceph` stops answering and
  imaptest commands hang until a mon is restored; the gap between the OUTAGE and
  RECOVERED markers is the unavailability window.
- **mds-failover**: a metadata stall while the standby replays the journal, then
  resume; recovery time = how long until an MDS is `active` again.
