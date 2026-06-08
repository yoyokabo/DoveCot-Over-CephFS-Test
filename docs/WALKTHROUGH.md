# Walkthrough: how the whole CephFS-for-Dovecot lab works

This document explains, step by step, every piece of the setup — the Ceph
cluster, the CRUSH rack topology, CephFS, the Dovecot-on-`ceph-fuse` mail
server, the imaptest load generator, and the failure experiments — and the key
design decisions and gotchas encountered while building it.

---

## 0. Why this exists, and why no S3

The goal is to evaluate **CephFS as Dovecot's mail storage** under a realistic
replicated, multi-rack topology, measuring **latency** and **failure recovery**.

S3 was deliberately dropped after investigation: **open-source Dovecot has no
native S3 mail backend.** S3 support lives only in the commercial Dovecot Pro
`obox`/`fs-s3` format; Community Edition's mail formats are file/POSIX-based
(maildir, mbox, sdbox, mdbox). The third-party `dovecot-ceph` (librmb) plugin
uses RADOS objects, not S3, and is lightly maintained. So the only genuinely
open-source, supported path is **CephFS mounted via `ceph-fuse`**, which is what
we test, in the two most relevant formats: **mdbox** (Dovecot's recommended
packed format) and **maildir** (one file per message — metadata/MDS-heavy worst
case).

---

## 1. The Ceph cluster (hand-rolled bootstrap)

We run a real multi-daemon Ceph cluster, each daemon in its own container, so we
can fail them independently. We bootstrap it by hand (not cephadm, which wants
systemd+podman on real hosts) using the upstream `quay.io/ceph/ceph:v18` (Reef)
image, which contains every Ceph binary.

### Daemons and why each count

- **3 monitors** (`mon1`/`mon2`/`mon3`): hold the authoritative cluster maps and
  form a Paxos **quorum** (majority). Three lets us (a) lose one and keep serving
  — the *failover* test — and (b) lose two to demonstrate *quorum loss*.
- **2 managers** (`mgr-a`/`mgr-b`): telemetry/health; active + standby.
- **4 OSDs** (`osd1`..`osd4`): the data. One per CRUSH rack (see §2).
- **2 MDS** (`mds-a`/`mds-b`): CephFS metadata; active + standby for the MDS
  failover test.
- **toolbox**: an always-on container with the `ceph` CLI + admin keyring; we run
  all init steps and queries through it (`docker compose exec -T toolbox ceph …`).

### Static IPs and the bootstrap rendezvous

All daemons sit on one docker network (`172.28.0.0/16`) with **static IPs**,
because the initial monitor `monmap` is built from fixed monitor IPs
(`.11/.12/.13`). A **shared docker volume `etc-ceph`** mounted on every daemon is
the rendezvous: `mon1` (the primary) bootstraps the cluster and writes
`ceph.conf`, the `mon.`/`client.admin` keyrings and the `monmap` there; every
other daemon waits for those to appear (`wait_for_bootstrap`) and for quorum
(`wait_for_quorum`, i.e. `ceph -s` succeeds) before starting.

The bootstrap logic lives in `ceph/lib.sh` (`bootstrap_cluster`, `mkfs_mon`,
the wait helpers) and is invoked by the per-role entrypoints
`ceph/entrypoint-{mon,mgr,osd,mds}.sh`.

> **Gotcha (bash `set -u`):** `local id="$1" datadir="…${id}"` expands `${id}`
> *before* `id` is assigned (all RHS expand first), tripping "unbound variable".
> Declare on separate lines. (See the note in `lib.sh:mkfs_mon`.)

### OSDs: file-backed BlueStore, RAM-backed storage

Each OSD is created on first boot following Ceph's manual-OSD procedure
(`ceph osd new` → BlueStore `--mkfs`), but its BlueStore **`block` device is just
a sparse file** (the "vstart" trick) — no real block device or loop device
needed. A marker file remembers the OSD id so a restarted container rejoins with
its existing data (essential for the OSD-down chaos test).

**Why the block files live on `/dev/shm` (host RAM):** the host's only data disk
is a 7200rpm HDD that's ~86% full. With size=3 replication, all 4 OSDs hammering
that one spindle produced **~200ms OSD commit latency** — so IMAP commands took
**12–15 seconds** and we'd be benchmarking the disk, not CephFS. tmpfs supports
`O_DIRECT` (which BlueStore needs), and `/dev/shm` survives container restarts,
so RAM-backing isolates the CephFS software path while keeping the chaos tests
working. After the switch, OSD commit latency dropped to ~0ms and IMAP append to
~350ms. (`.env` documents how to switch back to the HDD.)

---

## 2. CRUSH rack topology + replication rule

Each OSD pins itself into a distinct CRUSH **rack** at boot via
`--crush-location "root=default rack=rackN host=osdN"` (with
`osd_crush_update_on_start=true`), which also auto-creates the rack buckets:

```
root=default
  ├── rack1 → host osd1 → osd.x
  ├── rack2 → host osd2 → osd.x
  ├── rack3 → host osd3 → osd.x
  └── rack4 → host osd4 → osd.x
```

`ceph/apply-crush.sh` then creates the rule that makes replication
rack-aware:

```
ceph osd crush rule create-replicated rack_replicated default rack
```

`chooseleaf … type rack` forces each PG's 3 replicas into **3 distinct racks**.
With 4 racks, that leaves **one spare rack** so a single-OSD (== single-rack)
loss can be re-replicated onto the spare — i.e. **self-heal** — instead of just
sitting degraded. (With only 3 racks, a loss would stay degraded until the OSD
returns; the 4th rack is what makes the recovery test meaningful.)

`apply-crush.sh` also lowers `mon_osd_down_out_interval` to **30s** so a down OSD
is marked *out* (triggering self-heal backfill) quickly. The default is 600s —
which is why an early test sat degraded for minutes with no backfill.

---

## 3. The pools and CephFS

`scripts/create-pools.sh` creates two replicated pools on the `rack_replicated`
rule at size=3:

- **`cephfs_metadata`** — the directory tree / inodes (what the MDS constantly
  reads/writes; latency-critical).
- **`cephfs_data`** — the file contents (mail).

`scripts/create-fs.sh` runs `ceph fs new cephfs cephfs_metadata cephfs_data`,
sets `max_mds 1` + `standby_count_wanted 1` (one active MDS, one hot standby),
waits for an MDS to go active, and tags the pools (`application cephfs`) +
enables msgr2 so a fresh cluster reports clean **HEALTH_OK**.

---

## 4. Dovecot on `ceph-fuse`

`dovecot/Dockerfile` builds **FROM the ceph image** (so `ceph-fuse` and the ceph
client are present and version-matched) and installs **open-source Dovecot CE**
via dnf. We then **wipe the stock `conf.d/`** and use only our own heavily
commented config so nothing silently overrides settings.

`dovecot/entrypoint-dovecot.sh`:

1. **Mounts CephFS** at `/srv/mail` with `ceph-fuse -n client.admin` (it reads
   `ceph.conf` + the admin keyring from the read-only `etc-ceph` mount). The
   container needs `/dev/fuse` + `SYS_ADMIN` (set in compose).
2. **Renders the mail format** from `$MAIL_FORMAT` into
   `conf.d/01-mail-location.conf` — `mdbox:~/mdbox` or `maildir:~/Maildir`. This
   lets the benchmark switch formats by restarting Dovecot with a different env
   value (no rebuild).
3. **Generates test accounts** (`user0001`..`userNNNN`, plus a named user) into a
   passwd-file and creates their home dirs on CephFS. A provisioning marker on
   CephFS skips the slow per-restart `mkdir` loop (each dir is a FUSE round-trip).
4. **`exec dovecot -F`** in the foreground.

### CephFS-appropriate Dovecot tuning (a key correction)

The first attempt set `mail_nfs_storage=yes`, `mail_nfs_index=yes`,
`mmap_disable=yes`, `lock_method=dotlock` — conservative "shared FS" guesses.
Those are **NFS-specific** and force expensive index/cache invalidation; with a
**single** Dovecot instance on a coherent ceph-fuse mount they only add latency.
The final config (`01-mail-location.conf`) uses:

- `lock_method = fcntl` — ceph-fuse supports POSIX locks; far cheaper than dotlock.
- `mail_fsync = always` — kept, so APPEND latency reflects a *durable* write (a
  fair, honest measurement of the storage path).
- **no** `mail_nfs_*`.

Auth uses a passwd-file with `auth_username_format = %Ln` so IMAP logins
(`user0001`) and LMTP recipients (`user0001@bench.local`) map to the same entry.

> **Gotcha (`set -e`):** an `[[ cond ]] && action` line that is the *last*
> statement of a function returns non-zero when `cond` is false, which under
> `set -e` aborted startup before `exec dovecot` — but only on the *second* run
> (once the provisioning marker existed). Use explicit `if/then`.

---

## 5. imaptest load generator

`bench/Dockerfile` builds Dovecot's official **imaptest** tool.

> **Gotcha (the hard one):** imaptest must compile against a matching Dovecot.
> The CentOS `dovecot-devel` (2.3.16) carries distro patches (e.g. a changed
> `imap_parser_create` signature) that **no upstream imaptest commit matches**.
> So we build **upstream Dovecot 2.3.16 from source**, install it to
> `/usr/local`, and build the matching imaptest commit (≈Aug 2021) against that.

`bench/gen-corpus.sh` builds the APPEND source mbox with a realistic size mix
(~80% small 1–20 KB, ~20% large 50–512 KB). `bench/run-imaptest.sh` runs one
client-count and parses imaptest's `ms/cmd avg` lines (columns:
Logi List Stat Sele Fetc Fet2 Stor Dele Expu Appe Logo), averaging only the
non-zero samples per command into a CSV row.

**Command mix.** We use imaptest's **default profile** (no `profile=` file). Each
of the N concurrent connections logs in and loops a randomised mix against its
mailbox for the run duration. Per-command probabilities (from imaptest's output
header):

| Login | List | Status | Select | Fetch | Fetch2 | Store | Delete | Expunge | Append | Logout |
|------:|-----:|-------:|-------:|------:|-------:|------:|-------:|--------:|-------:|-------:|
| 100%  | 50%  | 50%    | 100%   | 100% (30%) | 100% | 50% (5%) | 100% | 100% | 100% | 100% |

Fetch has a ~30% chance of a second-pass fetch (Fetch2) and Append a ~5%
secondary variant (the parenthesised values). It is a deliberately **write-heavy
"mailbox churn" mix** — Append/Delete/Expunge all ~100% — so each connection
continuously adds and removes mail toward the `msgs≈50` target. That's why APPEND
dominates the latency numbers and why the metadata commands (List/Status/Select)
surface the maildir-vs-mdbox MDS-load difference. Treat it as a saturation/
worst-case probe, not a model of average human IMAP usage.

`scripts/run-benchmark.sh` orchestrates the **sweep**: for each format
(mdbox, maildir) it restarts Dovecot in that format, builds the corpus, and runs
imaptest across client counts (`25 50 100 200 400` by default), writing
`results/<ts>/<fmt>/sweep.csv` + per-step raw logs. Increasing latency with
client count reveals the **knee**; comparing the two CSVs is the
metadata-bound-vs-packed contrast.

---

## 6. Failure / recovery experiments

`chaos/measure-recovery.sh` is a host-side library: it drives imaptest under
**continuous load** (each output line epoch-stamped), samples `ceph health`
every 2s, and records timestamped **events**, all on one clock — so you can line
up client-visible latency against the cluster's recovery. An `EXIT` trap always
stops the load/sampler and restarts every daemon, so a timed-out run never leaves
the cluster crippled.

The four scenarios (`chaos/*.sh`):

| Script | Fault | Expected behaviour |
|--------|-------|--------------------|
| `osd-down.sh` | stop one OSD (one rack) | stays available on 2 surviving copies; after `mon_osd_down_out_interval` Ceph **self-heals** by backfilling onto rack4; then restart → HEALTH_OK |
| `mon-failover.sh` | stop 1 of 3 mons | quorum survives (2/3); brief re-election if the leader; cluster stays available |
| `mon-quorumloss.sh` | stop 2 of 3 mons | **no quorum** → client I/O stalls until a mon returns |
| `mds-failover.sh` | stop the active MDS | standby is promoted; CephFS metadata stalls during replay, then resumes |

Run any of them while the cluster is up; results land in
`results/chaos/<ts>-<scenario>/` (see [RESULTS.md](RESULTS.md)).

---

## 7. Lifecycle

- `scripts/up.sh` — start daemons + toolbox, wait healthy, apply CRUSH rule,
  create pools + CephFS, then start Dovecot + bench. Idempotent.
- `scripts/down.sh` — stop/remove containers (keep data). `--wipe` also removes
  volumes **and** the RAM-backed OSD data under `/dev/shm/ceph-osd*`.
- `scripts/wait-healthy.sh` — block until mons quorate + 4 OSDs in.
