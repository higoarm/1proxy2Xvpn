# Architecture

Deep technical reference for the `1proxy2Xvpn` system design.

---

## Table of Contents

1. [System Overview](#system-overview)
2. [Container Layer](#container-layer)
3. [Network Path](#network-path)
4. [Kill Switch Implementation](#kill-switch-implementation)
5. [DNS Leak Prevention](#dns-leak-prevention)
6. [Load Balancing](#load-balancing)
7. [Smart Routing Middleware](#smart-routing-middleware)
8. [Observability](#observability)
9. [Failure Modes](#failure-modes)
10. [Trust Boundaries](#trust-boundaries)

---

## System Overview

`1proxy2Xvpn` runs N isolated containers, each terminating an independent OpenVPN tunnel. Each container exposes a local HTTP proxy (tinyproxy on `:3128`) and SOCKS5 proxy (dante on `:1080`) to the host. HAProxy aggregates them into a single rotation endpoint.

```
                        ┌──────────────────────────────────┐
                        │           CLIENT TOOLS           │
                        │  (Burp, Nuclei, ffuf, sqlmap...) │
                        └────────────────┬─────────────────┘
                                         │
                                ┌────────▼────────┐
                                │  smart_router   │  Optional middleware
                                │   :9888         │  retries on 403/429/451
                                └────────┬────────┘
                                         │
                                ┌────────▼────────┐
                                │     HAProxy     │  TCP load balancer
                                │ :9999 / :9998   │  balance roundrobin
                                └────────┬────────┘
                                         │
              ┌──────────────────────────┼───────────────────────────┐
              │                          │                           │
         ┌────▼────┐                ┌────▼────┐                 ┌────▼────┐
         │ :3100   │                │ :3101   │       . . .     │ :3xxx   │
         │ Container 1               │ Container 2              │ Container N
         │ ──────────                │ ──────────               │ ──────────
         │ tinyproxy                 │ tinyproxy                │ tinyproxy
         │ dante                     │ dante                    │ dante
         │ OpenVPN ──┐               │ OpenVPN ──┐              │ OpenVPN ──┐
         │ iptables  │               │ iptables  │              │ iptables  │
         └───────────┼───────────────┴───────────┼──────────────┴───────────┼──
                     │                           │                          │
                  tun0 (VPN 1)               tun0 (VPN 2)               tun0 (VPN N)
                     │                           │                          │
                  VPN IP 1                    VPN IP 2                   VPN IP N
                     │                           │                          │
                                       INTERNET
```

Each container is **fully isolated** from the others: separate Linux network namespace, separate `tun0`, separate `iptables` rules. A breach in one container cannot affect others' tunnels or credentials.

---

## Container Layer

### Image composition

The Dockerfile (`docker/Dockerfile`) produces a single image with:

| Component | Version | Role |
|-----------|---------|------|
| Debian base | bookworm-slim | Minimal Linux userspace (~80 MB) |
| OpenVPN | 2.6.x | Tunnel client |
| tinyproxy | 1.11.x | HTTP/CONNECT proxy on :3128 |
| dante-server | 1.4.x | SOCKS5 proxy on :1080 |
| iptables | 1.8.x | Kill Switch and NAT |
| tini | bundled | PID 1, signal handling, zombie reaping |

### Capability set

Containers run with **no `--privileged`** flag. The minimum capabilities required:

| Capability | Why |
|------------|-----|
| `NET_ADMIN` | Configure routes, iptables, tun0 interface |
| `NET_RAW` | OpenVPN may need raw sockets for some protocols |

`--security-opt=no-new-privileges` is set to prevent privilege escalation via setuid binaries.

### Runtime user

Most processes drop to `nobody:nogroup` after initialization:

- `tinyproxy` — runs as `nobody`
- `danted` — runs as `nobody`
- `openvpn` — needs root for `tun0` and routing
- `entrypoint.sh` and monitor loop — needs root for iptables

### Container labels

Each container is labeled for service discovery:

```
1proxy2xvpn.managed=true
1proxy2xvpn.ovpn=my_expressvpn_us-newyork.ovpn
1proxy2xvpn.http_port=3100
1proxy2xvpn.socks_port=13100
```

Used by Promtail (log scraping) and the CLI cleanup logic.

---

## Network Path

### Inbound (client → target)

```
1. curl -x http://localhost:9999 https://target.com
2. → HAProxy :9999 accepts TCP connection
3. → balance roundrobin selects container N
4. → forwards bytes to 127.0.0.1:<port_N> (tinyproxy on container N)
5. → tinyproxy parses CONNECT or GET, opens upstream socket
6. → kernel routes via container's default route (tun0)
7. → encrypted OpenVPN packet → eth0 → VPN provider's server
8. → VPN provider's server forwards to target.com
9. → response traverses the same path in reverse
```

### Critical: traffic only ever exits via tun0

Inside the container, `iptables` policy is `OUTPUT DROP`. Only these flows are allowed:

- `lo` → `lo` (loopback)
- Established connections
- `OUTPUT` to VPN server IP on VPN port (handshake only)
- `OUTPUT` via `tun0` (all other traffic)
- `INPUT` on `:3128` and `:1080` (incoming proxy connections)

If `tun0` disappears (VPN drop), no rule matches outbound traffic → packet dropped. **Zero leak guarantee** unless the kernel itself is compromised.

---

## Kill Switch Implementation

### Three layers

**Layer 1 — Baseline (at container start, before any service)**

`/etc/1proxy2xvpn/baseline.rules` is `iptables-restore`'d as the first action in `entrypoint.sh`. It sets:

- All chains → `DROP`
- Loopback allowed
- Established connections allowed

This closes the **boot window** — the ~500ms between container start and the full Kill Switch being applied — which previously was a leak vector.

**Layer 2 — Full Kill Switch (after hostname resolution)**

`/usr/local/bin/iptables_killswitch.sh` applies the production rules:

```
INPUT  policy: DROP
OUTPUT policy: DROP
FORWARD policy: DROP

Then allow:
  - lo
  - conntrack ESTABLISHED,RELATED
  - OUTPUT to <VPN_IP>:<VPN_PORT>/<VPN_PROTO>   (handshake only)
  - OUTPUT via tun0                              (post-tunnel traffic)
  - INPUT on :3128, :1080                        (proxy access from host)

NAT:
  - POSTROUTING via tun0 with MASQUERADE

FORWARD:
  - eth0 → tun0 (allowed)
  - tun0 → eth0 (allowed, established only)

Logging:
  - Drops on default interface logged at limit 1/min (forensic)
```

**Layer 3 — Defensive re-apply on OpenVPN death**

The monitor loop in `entrypoint.sh` detects when OpenVPN dies and **re-applies the Kill Switch** in case any rules were modified. The container does not crash — it stays alive with no internet so HAProxy can deregister it cleanly.

### Why no DNS allowed at layer 2

Most implementations leave `OUTPUT to 53/udp` open as "DNS bootstrap" for hostname resolution. This **leaks** during reconnects: every time OpenVPN re-resolves the server hostname, a query goes via the host's DNS — visible to the ISP.

Our solution:

1. Resolve the VPN hostname **once**, at boot, before applying the Kill Switch.
2. Pin the result in `/etc/hosts` (`<VPN_IP> <VPN_HOSTNAME>`).
3. OpenVPN uses `/etc/hosts` instead of DNS, so no further queries are needed.
4. Post-tunnel DNS is forced via `tun0` by `redirect-gateway def1` and `block-outside-dns`.

---

## DNS Leak Prevention

### The threat

Even with a working VPN tunnel, DNS queries can leak via three paths:

1. **Bootstrap leak** — resolving the VPN server hostname before connecting (one-shot, recurring on reconnects)
2. **Side-channel leak** — apps using `getaddrinfo()` synchronously, hitting the host's resolver
3. **Default gateway leak** — Windows' `block-outside-dns` for OpenVPN; on Linux, `redirect-gateway`

### Our mitigations

| Vector | Mitigation |
|--------|-----------|
| Bootstrap | Pre-resolve to `/etc/hosts` (one query via host's DNS, then never again) |
| Side-channel | All DNS traffic forced through tun0 by route + iptables |
| Default gateway | `redirect-gateway def1 bypass-dhcp` injected into every `.ovpn` |
| OpenVPN-specific | `block-outside-dns` directive injected |

### Verification

To confirm no DNS leak in production, run from inside the container:

```bash
docker exec <container-name> bash -c '
  tcpdump -i eth0 -nn port 53 -c 5 &
  curl -sf https://api.ipify.org > /dev/null
  wait
'
```

Expected: zero packets captured (DNS via tun0 only).

---

## Load Balancing

HAProxy operates in **TCP mode** for both HTTP (`:9999`) and SOCKS5 (`:9998`) frontends. This is critical: TCP mode allows HTTPS `CONNECT` tunneling to work transparently. HTTP mode would require terminating TLS, which would defeat the purpose.

### Algorithm

`balance roundrobin` — connections are distributed sequentially across all
backends: server 1, then 2, 3, … N, then back to 1. This is chosen to
**maximize IP diversity**: every exit IP in the pool is used once before any is
reused. Compared to `random`:

- **No repeated IPs until the pool is exhausted.** `random` picks a uniformly
  random backend each time, so the same IP can be selected two or three times
  in a row by chance. Round-robin makes that impossible — you cycle through all
  N IPs first.
- Works with `option redispatch` (retry on a different backend if a connection
  fails) — a failed server is skipped and the next in sequence is used.
- DOWN servers (failed health checks) are automatically skipped in the rotation.

**Rotation granularity:** balancing happens per *connection* (TCP mode). A
client that opens a fresh connection per request (default `curl`) gets a new IP
each time. A client that reuses one keep-alive connection for many requests
keeps that connection's IP for its lifetime — disable keep-alive client-side
(see `docs/INTEGRATIONS.md`) for strict per-request rotation.

For session affinity (same client always gets same IP), see "Sticky sessions"
in the deployment notes — though that is the opposite of this tool's goal.

### Health checks

`check inter 5s rise 2 fall 3` — checks every 5s, marks UP after 2 successes, DOWN after 3 failures.

Current implementation uses TCP-level checks (port 3128 reachable). A future enhancement is HTTP-level checks via `option httpchk` that verify the proxy can actually reach the internet.

### Regional pools

Detected from `.ovpn` filename patterns. Example assignments:

| Filename pattern | Region backend |
|------------------|----------------|
| `*_us_*`, `*-us-*`, `*ca_*` | `http_vpn_pool_us` |
| `*_uk_*`, `*-uk-*`, `*-gb-*` | `http_vpn_pool_uk` |
| `*germany*`, `*france*`, `*netherlands*` | `http_vpn_pool_eu` |
| `*japan*`, `*singapore*`, `*hong*kong*` | `http_vpn_pool_asia` |
| `*brazil*`, `*-br-*` | `http_vpn_pool_sa` |
| `*australia*` | `http_vpn_pool_oceania` |

Use a regional pool by directing requests to the appropriate frontend (would require ACL configuration or separate ports per region — currently regional pools exist as backends ready for ACL routing).

---

## Smart Routing Middleware

The `middleware/smart_router.py` is an optional layer in front of HAProxy that adds **request-level intelligence**:

### Features

1. **Retry on status codes**: 403, 429, 451, 503 → retry up to 5 times with exponential backoff
2. **Each retry through HAProxy** advances `balance roundrobin` → the next (different) VPN IP
3. **Circuit breaker** per upstream: tracks burn rate, marks as burned after threshold
4. **Prometheus metrics** exposed at `:9888/metrics`

### When to use

- When your target has aggressive rate limiting and you want automatic IP rotation per failed request
- When testing WAFs and want to measure how many IPs get burned per request

### When NOT to use

- For HTTPS-heavy traffic (CONNECT method is not implemented — use HAProxy directly)
- When you need deterministic behavior (retries make request count non-deterministic)
- For traffic where ordering matters (state-dependent flows)

---

## Observability

### Metrics flow

```
1proxy2Xvpn containers ──┐
                         ├─► cAdvisor :8080 ──┐
HAProxy :8404 ────────────┘                    ├─► Prometheus :9090 ──► Grafana :3000
                                              │
host (proc/sys) ──► node-exporter :9100 ──────┘                         │
                                                                          │
                                                Loki :3100 ◄── Promtail ◄┘
                                                                          │
                                                                          ▼
                                                              Alertmanager :9093
                                                              → Discord/Slack/email
```

### Log flow

```
container stdout/stderr
    │
    ▼
Docker json-file driver
    │
    ▼
Promtail (watches /var/lib/docker/containers, filters by 1proxy2xvpn.managed=true label)
    │
    ▼
Loki (30-day retention, queryable via Grafana)
```

### Pre-built dashboard panels

1. VPN pool health (% UP)
2. Active container count
3. Requests per second (frontend)
4. p95 latency
5. CPU per container (time series)
6. Memory per container (time series)
7. Aggregate network throughput (TX/RX)
8. VPN backend states over time

### Alert thresholds

See `observability/prometheus/alerts.yml` for the production-tuned alert definitions.

---

## Failure Modes

| Failure | Detection | Impact | Recovery |
|---------|-----------|--------|----------|
| OpenVPN crashes | Monitor loop in entrypoint | Container has no internet | Kill Switch active, container stays alive; restart policy attempts reconnect |
| tinyproxy crashes | Monitor loop | Port 3128 not responding | Auto-restart; HAProxy marks DOWN after 3 fails |
| dante crashes | Monitor loop | Port 1080 not responding | Auto-restart |
| Container crashes | Docker daemon | One backend marked DOWN | `--restart=on-failure:10` retries up to 10 times |
| VPN credentials invalid | OpenVPN log shows AUTH_FAILED | Container in restart loop | Manual fix required — surface via `./1proxy2xvpn status` |
| HAProxy crashes | systemd | All proxies inaccessible | `systemctl restart haproxy` or systemd auto-restart |
| Host out of FDs | `dmesg` warnings | New connections refused | Increase `fs.file-max` (already tuned in `01_setup.sh`) |
| Host out of RAM | OOM killer | Random containers killed | Reduce container count or scale up host |
| /dev/net/tun missing | Container fails to start | All containers fail | `modprobe tun` on host |
| VPN provider blocks | API responses (target site) | Specific containers burned | Blacklist via `./1proxy2xvpn blacklist add` |

---

## Trust Boundaries

This system has three distinct trust zones:

```
┌─────────────────────────────────────────────────────────────────┐
│  Zone 1: HOST                                                   │
│   - Root access here = full compromise                          │
│   - Operator's responsibility to secure                         │
│   - Recommendation: dedicated host, audit logging               │
└─────────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────┐
│  Zone 2: CONTAINERS                                             │
│   - Isolated network namespaces                                 │
│   - Minimal capabilities (NET_ADMIN, NET_RAW)                   │
│   - Read-only mount of .ovpn (per-container, not shared)        │
│   - Cannot affect host or other containers                      │
└─────────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────┐
│  Zone 3: VPN PROVIDER                                           │
│   - Outside our control                                         │
│   - Sees all your traffic in plaintext (post-TLS)               │
│   - Vet providers carefully — they're the ultimate trust point  │
└─────────────────────────────────────────────────────────────────┘
```

A compromised container cannot:
- Access other containers' `.ovpn` files (mounted per-container)
- Modify host networking (no privileged access)
- Escape via `/proc` or `/sys` (read-only mounted)
- Affect HAProxy or the smart router (separate processes)

A compromised host can do anything — that's why operational security at the host level is critical.
