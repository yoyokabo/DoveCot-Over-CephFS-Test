# CephFS-for-Dovecot Benchmark Harness

A self-contained lab that benchmarks **CephFS (via `ceph-fuse`) as the storage
backend for Dovecot mail**, measuring **latency** and **failure recovery /
tolerance** on a replicated, multi-rack Ceph cluster — all in Docker on one host.

Each Ceph "rack" is a separate container. Pools are **replicated size=3 with
CRUSH failure domain = rack**, across **4 racks** (one OSD each); the 4th rack is
spare capacity so a single-OSD loss **self-heals**. Dovecot runs on a `ceph-fuse`
mount and is driven by **imaptest** in two mail formats (**mdbox** and
**maildir**).

> **Scope note.** S3 is intentionally out of scope: open-source Dovecot has no
> native S3 mail backend (S3 lives only in the commercial Pro `obox`/`fs-s3`).
> The access path under test is CephFS via `ceph-fuse`. See
> [docs/WALKTHROUGH.md](docs/WALKTHROUGH.md) for the full rationale.

---

## TL;DR

```bash
./scripts/up.sh                 # build + start the whole lab, reach HEALTH_OK
./scripts/run-benchmark.sh      # latency sweep, mdbox vs maildir -> results/<ts>/
./chaos/osd-down.sh             # single-OSD failure + self-heal (under load)
./chaos/mon-failover.sh         # kill 1/3 mons (quorum survives)
./chaos/mon-quorumloss.sh       # kill 2/3 mons (I/O stalls)
./chaos/mds-failover.sh         # active MDS dies, standby takes over
./scripts/down.sh               # stop (keep data)   |   --wipe for a full reset
```

Results (latency CSVs, raw imaptest logs, failure timelines) land in `results/`.

---

## Topology

| Component | Containers | Purpose |
|-----------|-----------|---------|
| Monitors  | `mon1` (.11, bootstrap), `mon2` (.12), `mon3` (.13) | cluster maps + Paxos quorum; enables MON failover / quorum-loss tests |
| Managers  | `mgr-a` (.21), `mgr-b` (.22) | stats / health; active + standby |
| OSDs      | `osd1`..`osd4` (.31-.34) | object storage, one per CRUSH rack; RAM-backed (see below) |
| MDS       | `mds-a` (.41), `mds-b` (.42) | CephFS metadata; active + standby (MDS failover test) |
| Toolbox   | `toolbox` (.60) | always-on `ceph` CLI + admin keyring; runs init + queries |
| Dovecot   | `dovecot` (.51) | `ceph-fuse` mount of CephFS + IMAP/LMTP |
| Bench     | `bench` (.61) | `imaptest` load generator |

All on one docker network `172.28.0.0/16` with **static IPs** (the monitor
monmap is built from fixed IPs).

```
root=default
  ├── rack1 → osd1     pools: cephfs_metadata, cephfs_data
  ├── rack2 → osd2       rule: rack_replicated (size=3, failure domain=rack)
  ├── rack3 → osd3       => 3 copies in 3 distinct racks; rack4 = spare
  └── rack4 → osd4
```

### Why the OSDs are RAM-backed

This host's only data disk is a **7200rpm HDD that's ~86% full**. With size=3
replication, all 4 OSDs hammering one spindle gave **~200ms OSD commit latency**,
so the benchmark measured the *disk*, not CephFS (IMAP commands took 12–15s).
The OSD BlueStore block files therefore live on the host's **tmpfs (`/dev/shm`)**,
which isolates the CephFS software path (ceph-fuse + MDS + replication + Dovecot)
— the thing we actually want to compare. `/dev/shm` survives container restarts,
so the OSD-down chaos test still reuses its data. To benchmark the real HDD
instead, switch the OSD volumes back to named volumes (commented in
`docker-compose.yml`).

---

## What gets measured

- **Latency sweep** (`scripts/run-benchmark.sh`): imaptest at increasing client
  counts (25→400) for **both mdbox and maildir**, producing a per-command
  latency curve (`results/<ts>/<fmt>/sweep.csv`) so you can find the knee and
  contrast metadata-bound (maildir) vs packed (mdbox) storage.
- **Failure/recovery** (`chaos/*.sh`): faults injected **while imaptest holds
  load**, capturing a timestamped timeline (`results/chaos/<ts>-<scenario>/`)
  with `imaptest.log` (client latency), `events.log` (fault/recovery markers),
  and `health.log` (cluster health every 2s) on a shared clock.

See [docs/WALKTHROUGH.md](docs/WALKTHROUGH.md) for a step-by-step explanation of
every component and config file, and [docs/RESULTS.md](docs/RESULTS.md) for how
to read the outputs.

---

## Requirements

Docker + Compose v2, `/dev/fuse` on the host (for `ceph-fuse`), a few GB of RAM
free for the RAM-backed OSDs. No Ceph/Dovecot install needed on the host —
everything runs in containers built from `quay.io/ceph/ceph:v18`.

## Layout

```
docker-compose.yml      all services + network + volumes
.env                    cluster + benchmark configuration (heavily commented)
ceph/                   per-role daemon entrypoints + lib.sh + apply-crush.sh
dovecot/                Dockerfile, conf.d/, ceph-fuse mount + entrypoint
bench/                  Dockerfile (imaptest), corpus + sweep scripts
scripts/                up/down/wait-healthy, pool/fs creation, run-benchmark
chaos/                  measure-recovery.sh + the 4 failure scenarios
results/                run outputs (gitignored)
docs/                   WALKTHROUGH.md, RESULTS.md
```
