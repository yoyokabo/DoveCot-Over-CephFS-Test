# CephFS-for-Dovecot Benchmark — Final Report

**Date:** 2026-06-07
**Cluster:** 4-rack replicated Ceph (Reef v18.2), CephFS via `ceph-fuse`, Dovecot CE 2.3.16
**Workload:** Dovecot `imaptest`, 100 simulated users, mixed message corpus (~80% 1–20 KB, ~20% 50–512 KB)
**Raw data:** `results/20260607-215443/` (sweep) and `results/chaos/20260607-22*/` (failures)

---

## 1. Executive summary

- **CephFS via `ceph-fuse` is a viable Dovecot backend** for small/medium load. With
  RAM-backed OSDs (to remove the host HDD as a bottleneck), per-command latency stays in
  the low-hundreds of ms up to ~50–100 concurrent IMAP clients, then climbs steeply — the
  **knee is around 100–200 clients** for this 4-OSD cluster.
- **mdbox clearly outperforms maildir under load.** At 400 clients, maildir is **~1.5–2×
  slower** across the board (append 7.4 s vs 4.2 s; list/select ~3.6 s vs ~1.7 s) because
  its one-file-per-message model multiplies CephFS **MDS metadata** operations.
- **Failure tolerance is strong.** A full OSD/rack loss is **survived with no outage** and
  **self-heals in ~46 s** onto the spare rack; monitor failover (1/3) and MDS failover are
  near-transparent (seconds). Only deliberate **quorum loss (2/3 monitors)** causes a real
  client stall, which clears within seconds of restoring a monitor.

**Recommendation:** for Dovecot on CephFS, use **mdbox**, keep concurrent connections per
backend well below the knee (here <100), give the MDS fast metadata storage, and rely on
size=3 across racks for availability. Provision OSD capacity generously — a full pool stops
all writes and hangs clients.

---

## 2. Environment & methodology

| | |
|---|---|
| Ceph | Reef v18.2; 3 MON, 2 MGR, **4 OSD (one per CRUSH rack)**, 2 MDS (active+standby) |
| Replication | replicated **size=3**, **failure domain = rack**, spare 4th rack for self-heal |
| OSD storage | file-backed BlueStore on **tmpfs (`/dev/shm`)**, 6 GB each — see caveat §5 |
| Client path | Dovecot CE on a **`ceph-fuse`** mount (`fcntl` locking, `mail_fsync=always`) |
| Load tool | `imaptest` (login/list/status/select/fetch/store/delete/expunge/append/logout mix) |
| Sweep | client counts **25 → 50 → 100 → 200 → 400**, 60 s each, 100 users, msgs≈50/mailbox |
| Failures | injected **while imaptest holds 100-client load**; cluster health sampled every 2 s |

All latencies below are **average ms per command** (imaptest `ms/cmd avg`, non-zero
samples). Each fault test records a shared-clock timeline of client latency + cluster
health (`results/chaos/<ts>-<scenario>/`).

---

## 3. Latency sweep results

### mdbox (Dovecot's recommended packed format)

| clients | append | list | status | select | fetch | store | delete | expunge |
|--------:|-------:|-----:|-------:|-------:|------:|------:|-------:|--------:|
| 25  | 177  | 126  | 122  | 119  | 108  | 104  | 150  | 126  |
| 50  | 458  | 162  | 133  | 121  | 183  | 205  | 292  | 244  |
| 100 | 964  | 365  | 304  | 290  | 341  | 408  | 567  | 495  |
| 200 | 1977 | 760  | 693  | 637  | 666  | 775  | 1054 | 981  |
| 400 | 4226 | 1702 | 1796 | 1614 | 1426 | 1736 | 2136 | 2097 |

### maildir (one file per message — metadata/MDS-bound)

| clients | append | list | status | select | fetch | store | delete | expunge |
|--------:|-------:|-----:|-------:|-------:|------:|------:|-------:|--------:|
| 25  | 176  | 199  | 277  | 269  | 82   | 100  | 109  | 88   |
| 50  | 534  | 239  | 235  | 222  | 165  | 212  | 252  | 220  |
| 100 | 1261 | 434  | 469  | 421  | 288  | 390  | 432  | 397  |
| 200 | 3697 | 1035 | 1149 | 1056 | 716  | 973  | 1097 | 1029 |
| 400 | 7403 | 3651 | 3693 | 3547 | 3049 | 3880 | 3862 | 3892 |

*(Login latency is omitted: the 25-client first sample is a cold-cache outlier — 2.7 s
mdbox / 12 s maildir on the very first connection — and is ~5 ms once warm.)*

### Reading the curves

- **Both formats scale roughly linearly-to-super-linearly with load.** Latency about
  doubles each time the client count doubles past 50; the **knee** (where it stops being
  flat and starts hurting) sits around **100–200 clients** for 4 OSDs.
- **APPEND is the most expensive command** in both formats — it writes a message, updates
  indexes, and `fsync`s, all replicated 3×.
- **mdbox vs maildir:** comparable at light load, but maildir degrades faster. At 400
  clients maildir's metadata commands (list/status/select) are **~2× slower** (≈3.6 s vs
  ≈1.7 s) and append is **~1.75×** slower (7.4 s vs 4.2 s). This is the expected cost of
  maildir's per-message file create/rename/unlink, each a CephFS **MDS** round-trip — the
  single busiest component in a CephFS mail deployment.

---

## 4. Failure / recovery results

Injected at **100-client load** (representative mid-load point). All recovery times from
`events.log`.

| Scenario | What happened | Client impact | Recovery |
|---|---|---|---|
| **Single OSD / rack down** (`osd-down`) | size=3 across 4 racks → 2 copies survive; after `mon_osd_down_out_interval` (30 s) Ceph re-replicates onto the spare rack4 | **stayed available** (≈700 op/s throughout); append rose ≈964 ms → ≈1300 ms, with a transient ≈2.5 s spike during backfill | **self-heal ≈46 s** to `active+clean`; OSD restart → `HEALTH_OK` in ≈2 s |
| **MON failover, 1 of 3** (`mon-failover`) | surviving 2/3 keep quorum; new leader elected | **negligible** — cluster responsive again in ≈2 s | `HEALTH_OK` ≈4 s after restart |
| **MDS failover** (`mds-failover`) | active MDS killed; hot standby promoted, replays journal | brief metadata stall during replay | **standby active ≈12 s**; `HEALTH_OK` ≈14 s |
| **MON quorum loss, 2 of 3** (`mon-quorumloss`) | only 1/3 mons → **no quorum**, cluster stops serving maps | **client I/O stalls** for the outage window | mons responsive **≈16 s** after a monitor is restored; `HEALTH_OK` same |

### Takeaways

- The **4th (spare) rack is what makes self-heal possible**: with only 3 racks a single-OSD
  loss would sit degraded until the OSD returned. With 4, Ceph rebuilds full redundancy
  automatically while staying online.
- **Availability ≠ no latency cost:** during degraded operation + backfill, client latency
  rose ~35% with a brief ~2.5× spike — usable, not free.
- **Quorum loss is the only hard outage**, and it's by design (majority consensus). 3
  monitors tolerate 1 failure transparently; losing 2 is the tolerance boundary.

---

## 5. Caveats & honest notes

- **OSDs are RAM-backed (tmpfs).** The host's only data disk is a 7200rpm HDD at ~86% full;
  on it, 3× replication produced ~200 ms OSD commit latency and 12–15 s IMAP commands — i.e.
  we'd be benchmarking the disk. RAM-backing isolates the **CephFS software path**
  (ceph-fuse + MDS + replication + Dovecot), which is the intended comparison. **Absolute
  latencies on real SSD/NVMe will differ**, but the *shape* (knee location, mdbox-vs-maildir
  ratio, failure behaviour) is representative. Switch to HDD-backed OSDs via the commented
  volumes in `docker-compose.yml` to measure this host's disk reality.
- **`ceph-fuse`, not the kernel client.** Per the test scope; the kernel CephFS mount is
  generally faster, so these are conservative (worst-of-the-two-clients) numbers.
- **`mail_fsync=always`** is kept, so APPEND latency reflects a *durable* write — a fair,
  honest cost.
- **Capacity matters:** an early run filled the 4 GB OSDs mid-sweep; a full pool blocks all
  writes and hangs the ceph-fuse mount. OSDs were sized to 6 GB; on real deployments size
  for peak mailbox growth plus backfill headroom.
- **S3 is out of scope** — open-source Dovecot has no native S3 mail backend (Pro-only
  `obox`/`fs-s3`); see [WALKTHROUGH.md](WALKTHROUGH.md) §0.

---

## 6. Conclusions

1. **CephFS-via-`ceph-fuse` is a workable Dovecot backend** with good failure tolerance;
   replicate size=3 across racks and it survives node loss with automatic self-heal.
2. **Use mdbox, not maildir** — maildir's per-message files make the MDS the bottleneck and
   it degrades ~2× faster under concurrency.
3. **Scale out before the knee** (~100 clients/backend here) — add OSDs/MDS capacity or more
   Dovecot backends rather than pushing one cluster past saturation.
4. **The MDS is the component to protect and provision** for mail-on-CephFS: keep its
   metadata pool fast and run a standby (failover was ~12 s here).

### Reproduce

```bash
./scripts/up.sh
./scripts/run-benchmark.sh          # regenerates the §3 tables under results/<ts>/
for s in osd-down mon-failover mds-failover mon-quorumloss; do ./chaos/$s.sh; done
```
