#!/usr/bin/env bash
# =============================================================================
# entrypoint-dovecot.sh — mount CephFS via ceph-fuse, then run Dovecot.
#
# Steps:
#   1. ceph-fuse mounts the CephFS root at /srv/mail (the vmail home base), so
#      ALL mailboxes physically live on CephFS — that is the whole point.
#   2. Render the mail_location config from $MAIL_FORMAT (mdbox | maildir).
#   3. Generate the passwd-file of test accounts + per-user home dirs.
#   4. exec dovecot in the foreground.
#
# Env: MAIL_FORMAT, MAIL_USER_COUNT, MAIL_TEST_USER, MAIL_TEST_PASS (from .env)
# =============================================================================
set -euo pipefail

MOUNT=/srv/mail
FORMAT="${MAIL_FORMAT:-mdbox}"
USERS="${MAIL_USER_COUNT:-100}"
PASS="${MAIL_TEST_PASS:-pass}"

log() { echo "[$(date +%H:%M:%S)] [dovecot] $*"; }

# --- 1. Mount CephFS --------------------------------------------------------
mkdir -p "${MOUNT}"
if mountpoint -q "${MOUNT}"; then
  log "CephFS already mounted at ${MOUNT}"
else
  log "mounting CephFS at ${MOUNT} via ceph-fuse (client.admin)"
  # ceph-fuse reads /etc/ceph/ceph.conf (mon_host) + the admin keyring. It
  # forks into the background once the mount is ready.
  ceph-fuse -n client.admin "${MOUNT}"
  for _ in $(seq 1 30); do
    mountpoint -q "${MOUNT}" && break
    sleep 1
  done
  mountpoint -q "${MOUNT}" || { log "ERROR: CephFS mount failed"; exit 1; }
  log "CephFS mounted."
fi
# The vmail user owns its mail tree on CephFS.
chown vmail:vmail "${MOUNT}"

# --- 2. Render mail_location from MAIL_FORMAT -------------------------------
case "${FORMAT}" in
  mdbox)   LOCATION="mdbox:~/mdbox" ;;
  maildir) LOCATION="maildir:~/Maildir" ;;
  *) log "ERROR: unknown MAIL_FORMAT='${FORMAT}' (use mdbox|maildir)"; exit 1 ;;
esac
log "mail format = ${FORMAT}  ->  mail_location = ${LOCATION}"
cat > /etc/dovecot/conf.d/01-mail-location.conf <<EOF
# Generated at startup from MAIL_FORMAT=${FORMAT}. Do not edit by hand.
mail_location = ${LOCATION}
mail_uid = vmail
mail_gid = vmail
first_valid_uid = 5000

# --- CephFS tuning ----------------------------------------------------------
# A SINGLE Dovecot instance mounts CephFS here, and ceph-fuse provides a
# coherent, cap-based cache plus working POSIX (fcntl) locks. So:
#   * use fcntl locking (ceph-fuse supports it; far cheaper than dotlock)
#   * do NOT enable mail_nfs_storage/mail_nfs_index — those force expensive
#     index/cache invalidation meant for NFS and cause multi-second stalls on
#     CephFS for no benefit with a single backend.
#   * keep mail_fsync=always so APPEND latency reflects a durable write
#     (a fair, honest measurement of the storage path).
lock_method = fcntl
mail_fsync = always
EOF

# --- 3. Generate test accounts + home dirs ----------------------------------
# The passwd-file is container-local, so we always regenerate it (fast). The
# per-user home dirs live on CephFS and persist across restarts; creating 100+
# of them is slow over FUSE (a metadata round-trip each), so we skip that step
# when a provisioning marker for this user count already exists on CephFS.
MARKER="${MOUNT}/.provisioned-${USERS}"
MAKE_DIRS=1
if [[ -f "${MARKER}" ]]; then
  MAKE_DIRS=0
  log "home dirs already provisioned (${MARKER}); skipping mkdir"
fi

log "generating ${USERS} test accounts + the named test user (mkdir=${MAKE_DIRS})"
: > /etc/dovecot/users
# NOTE: use explicit if/then (not `cond && action`) so a false condition can't
# return non-zero and trip `set -e` and skip the rest of startup.
emit_user() {
  local u="$1"
  echo "${u}:{PLAIN}${PASS}:5000:5000::/srv/mail/${u}::" >> /etc/dovecot/users
  if [[ "${MAKE_DIRS}" == "1" ]]; then
    install -d -o vmail -g vmail "${MOUNT}/${u}"
  fi
}
for i in $(seq 1 "${USERS}"); do
  emit_user "$(printf 'user%04d' "${i}")"
done
emit_user "${MAIL_TEST_USER:-user}"
if [[ "${MAKE_DIRS}" == "1" ]]; then
  touch "${MARKER}"
fi
# The Dovecot auth process runs as the unprivileged 'dovecot' user, so the
# passwd-file must be group-readable by it. Lab only (plaintext passwords).
chown root:dovecot /etc/dovecot/users
chmod 640 /etc/dovecot/users

# --- 4. Run Dovecot ---------------------------------------------------------
log "starting dovecot (foreground)"
exec dovecot -F
