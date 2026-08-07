# =============================================================================
# 1proxy2Xvpn — Hardened container image
# Multi-stage build, minimal attack surface, no unnecessary capabilities
# =============================================================================
FROM debian:bookworm-slim AS base

LABEL org.opencontainers.image.title="1proxy2xvpn"
LABEL org.opencontainers.image.description="HTTP/SOCKS5 proxy through OpenVPN with Kill Switch"
LABEL org.opencontainers.image.source="https://github.com/higoarm/1proxy2Xvpn"
LABEL org.opencontainers.image.licenses="MIT"

# Install packages WITHOUT strict pinning (Debian's package versions are stable
# within a release; let apt resolve actual versions). For reproducible builds,
# pin via `apt-mark hold` or use a custom registry.
# hadolint ignore=DL3008
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        tinyproxy \
        dante-server \
        openvpn \
        iptables \
        iproute2 \
        dnsutils \
        curl \
        ca-certificates \
        procps \
        tini \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && apt-get clean

# Create unprivileged user for runtime processes that don't need root
RUN groupadd --system --gid 9999 proxy2vpn \
    && useradd --system --uid 9999 --gid proxy2vpn --no-create-home --shell /usr/sbin/nologin proxy2vpn

# Ensure /dev/net/tun exists (fallback — host must expose it)
RUN mkdir -p /dev/net \
    && { mknod /dev/net/tun c 10 200 2>/dev/null || true; } \
    && { chmod 0666 /dev/net/tun 2>/dev/null || true; }

# Required runtime directories with correct ownership
RUN mkdir -p /var/run/tinyproxy /var/log/1proxy2xvpn /etc/1proxy2xvpn /etc/dante \
    && chown -R proxy2vpn:proxy2vpn /var/run/tinyproxy /var/log/1proxy2xvpn

# Copy configuration and runtime scripts
COPY --chmod=0644 tinyproxy.conf         /etc/tinyproxy/tinyproxy.conf
COPY --chmod=0644 danted.conf            /etc/dante/danted.conf
COPY --chmod=0644 custom_error.html      /etc/tinyproxy/custom_error.html
COPY --chmod=0755 entrypoint.sh          /usr/local/bin/entrypoint.sh
COPY --chmod=0755 iptables_killswitch.sh /usr/local/bin/iptables_killswitch.sh
COPY --chmod=0755 healthcheck.sh         /usr/local/bin/healthcheck.sh

# Pre-apply baseline iptables DROP policy via savefile loaded at container start
COPY --chmod=0644 iptables-baseline.rules /etc/1proxy2xvpn/baseline.rules

# Use tini as PID 1 for proper signal handling and zombie reaping
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

# Container-level healthcheck (semantic — verifies VPN is actually working)
HEALTHCHECK --interval=60s --timeout=8s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh || exit 1

EXPOSE 3128 1080
