ARG BASE=ubuntu:24.04
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    systemd systemd-sysv dbus \
    python3 python3-pip curl wget ca-certificates gnupg iproute2 unzip \
    && rm -rf /var/lib/apt/lists/*
# rm -rf of the apt lists above is deliberate: it reproduces the
# fresh-machine state where `gh : Depends: git` is unresolvable unless
# ensure_gh.sh falls back to a full apt-get update.
RUN systemctl mask systemd-resolved systemd-networkd systemd-logind getty@tty1.service \
    console-getty.service systemd-udevd systemd-udev-trigger || true
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
