# =============================================================================
# Dovecot + ceph-fuse image.
#
# We start FROM the Ceph image (so ceph-fuse and the ceph client libs/config
# tooling are already present and exactly version-matched to the cluster), then
# layer the open-source Dovecot Community Edition on top via dnf. This gives a
# single container that can both mount CephFS (ceph-fuse) and serve IMAP/LMTP.
# =============================================================================
ARG CEPH_IMAGE=quay.io/ceph/ceph:v18
FROM ${CEPH_IMAGE}

# Dovecot CE + the LMTP/IMAP protocol packages, plus fuse userspace for
# ceph-fuse. (ceph-fuse itself ships in the base ceph image.)
RUN dnf install -y --setopt=install_weak_deps=False \
        dovecot \
        fuse \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Virtual mail user. All mailboxes are owned by this single uid/gid; Dovecot
# maps every authenticated account onto it (classic virtual-user setup).
RUN groupadd -g 5000 vmail && \
    useradd  -u 5000 -g 5000 -d /srv/mail -s /sbin/nologin vmail

# Static Dovecot config (protocol-independent bits). The mail_location is
# generated at runtime from $MAIL_FORMAT by the entrypoint.
COPY dovecot.conf /etc/dovecot/dovecot.conf
COPY conf.d/ /etc/dovecot/conf.d/

EXPOSE 143 24
