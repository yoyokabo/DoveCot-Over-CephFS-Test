# =============================================================================
# Bench image = Ceph CLI base + Dovecot's imaptest.
#
# imaptest is Dovecot's official IMAP load/benchmark tool. It must be compiled
# against a matching Dovecot. We CANNOT use the CentOS dovecot-devel package:
# its 2.3.16 build carries distro patches (e.g. a changed imap_parser_create
# signature) that no upstream imaptest commit matches. So we build UPSTREAM
# Dovecot 2.3.16 from source, install it to /usr/local, and build imaptest
# against that — a clean, self-consistent toolchain.
#
# We start FROM the ceph image so the bench container also has the `ceph` CLI
# on the cluster network (handy for correlating load with cluster state).
# =============================================================================
ARG CEPH_IMAGE=quay.io/ceph/ceph:v18
FROM ${CEPH_IMAGE}

ARG DOVECOT_VERSION=2.3.16
# imaptest commit matching upstream Dovecot 2.3.16 (dated just before we pin).
ARG IMAPTEST_BEFORE=2021-09-15

# Build toolchain + libs needed to compile Dovecot and imaptest. (No
# dovecot/dovecot-devel package — we build Dovecot from source below.)
RUN dnf install -y --setopt=install_weak_deps=False \
        git autoconf automake libtool make gcc gcc-c++ pkgconfig \
        openssl-devel zlib-devel \
        bc gawk procps-ng \
    && dnf clean all && rm -rf /var/cache/dnf
    # (curl is already present as curl-minimal in the base image)

# 1. Build + install upstream Dovecot 2.3.16 to /usr/local (provides libdovecot
#    + the dovecot-config build descriptor imaptest needs).
RUN cd /tmp \
    && curl -fsSL "https://dovecot.org/releases/2.3/dovecot-${DOVECOT_VERSION}.tar.gz" -o dovecot.tgz \
    && tar xzf dovecot.tgz \
    && cd "dovecot-${DOVECOT_VERSION}" \
    && ./configure --without-pam --without-ldap --without-sqlite \
                   --without-pgsql --without-mysql >/dev/null \
    && make -j"$(nproc)" >/dev/null \
    && make install >/dev/null \
    && echo /usr/local/lib > /etc/ld.so.conf.d/dovecot-local.conf && ldconfig

# 2. Build + install imaptest against the freshly installed Dovecot.
RUN git clone https://github.com/dovecot/imaptest /tmp/imaptest \
    && cd /tmp/imaptest \
    && git checkout "$(git rev-list -1 --before="${IMAPTEST_BEFORE}" origin/main)" \
    && ./autogen.sh >/dev/null \
    && ./configure --with-dovecot=/usr/local/lib/dovecot >/dev/null \
    && make -j"$(nproc)" >/dev/null \
    && make install >/dev/null \
    && test -x /usr/local/bin/imaptest \
    && rm -rf /tmp/dovecot.tgz "/tmp/dovecot-${DOVECOT_VERSION}" /tmp/imaptest

ENV PATH=/usr/local/bin:$PATH
