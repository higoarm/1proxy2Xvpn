FROM debian:bookworm-slim

LABEL maintainer="1proxy2Xvpn"
LABEL description="tinyproxy HTTP Proxy + OpenVPN client with Kill Switch"

RUN apt-get update && apt-get install -y --no-install-recommends \
        tinyproxy \
        openvpn \
        iptables \
        iproute2 \
        iputils-ping \
        dnsutils \
        curl \
        net-tools \
        procps \
    && rm -rf /var/lib/apt/lists/*

# Create TUN device (fallback — host should expose /dev/net/tun)
RUN mkdir -p /dev/net \
    && (mknod /dev/net/tun c 10 200 2>/dev/null || true) \
    && chmod 0666 /dev/net/tun 2>/dev/null || true

COPY tinyproxy.conf         /etc/tinyproxy/tinyproxy.conf
COPY entrypoint.sh          /usr/local/bin/entrypoint.sh
COPY iptables_killswitch.sh /usr/local/bin/iptables_killswitch.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/iptables_killswitch.sh

EXPOSE 3128

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
