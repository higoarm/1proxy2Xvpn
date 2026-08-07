# 1proxy2Xvpn

[![CI](https://github.com/higoarm/1proxy2Xvpn/actions/workflows/ci.yml/badge.svg)](https://github.com/higoarm/1proxy2Xvpn/actions/workflows/ci.yml)
[![Security](https://github.com/higoarm/1proxy2Xvpn/actions/workflows/security.yml/badge.svg)](https://github.com/higoarm/1proxy2Xvpn/actions/workflows/security.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **Distributed HTTP/SOCKS5 proxy infrastructure** — one isolated container per OpenVPN tunnel, with a hardened Kill Switch, intelligent load balancing, and full observability. Built for authorized security research and Bug Bounty operations at scale.

```
Client → smart_router → HAProxy :9999 → tinyproxy :3128 → tun0 (OpenVPN) → VPN IP → Internet
            (retry)      (load balance)   (HTTP proxy)    (Kill Switch)
```

---

## Why this exists

Security professionals running large-scale authorized assessments need:

- **IP diversity** to bypass per-IP rate limiting without breaking program policies
- **Geographic distribution** for geo-restricted target validation
- **Isolation** so a single compromised proxy can't leak others' credentials
- **Reliability** at the scale of hundreds of simultaneous connections
- **Observability** to know exactly which IPs are burned, when, and why

`1proxy2Xvpn` provides all of the above with hardened defaults, a CLI workflow, and a production-ready operations layer.

---

## ⚠️ Ethical use

This tool is intended **exclusively for authorized security testing**: Bug Bounty programs (HackerOne, Intigriti, Bugcrowd), Vulnerability Disclosure Programs (VDP), authorized penetration tests, and academic research with proper consent.

**Never test systems you do not own or have explicit written permission to assess.** Unauthorized use may violate computer crime laws in your jurisdiction.

---

## Features

### Architecture
- **One container per VPN endpoint** — full isolation between tunnels
- **Hardened containers** — no `--privileged`, minimal Linux capabilities
- **Boot-time Kill Switch** — `iptables` deny-by-default applied before any service starts
- **DNS leak prevention** — pre-resolved hostnames, no bootstrap DNS path
- **HTTP + SOCKS5** — both protocols available per container (tinyproxy + dante-server)
- **Anti-fingerprint** — sanitized error pages, removed identifying headers

### Operations
- **Unified CLI** — single `1proxy2xvpn` command for all operations
- **Auto-discovery** — HAProxy config regenerates from running containers
- **Regional pools** — automatic grouping by country code in filename
- **Blacklist API** — disable burned IPs without restarting infrastructure
- **Smart retry middleware** — automatic IP rotation on 403/429/451

### Observability
- **Prometheus metrics** — per-container, HAProxy, host
- **Grafana dashboards** — pre-built overview with throughput, latency, health
- **Loki log aggregation** — centralized container logs
- **Alertmanager** — critical alerts to Discord/Slack/email
- **cAdvisor + Node Exporter** — full host and container metrics

### DevSecOps
- **CI pipelines** — shellcheck, hadolint, yamllint, ruff
- **Security scans** — Trivy (CVEs), Gitleaks (secrets) on every push
- **Multi-arch builds** — amd64 + arm64 via GitHub Actions
- **Pre-commit hooks** — catch issues before they reach git

---

## Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| OS | Linux kernel 5.x | Linux kernel 6.x |
| CPU | 4 cores | 16 cores |
| RAM | 8 GB | 32 GB |
| Disk | 40 GB SSD | 100 GB SSD |
| Network | 100 Mbps | 1 Gbps |
| Docker | 20.10 | 24.x |
| HAProxy | 2.4 | 2.8+ |

For 300+ containers, see [recommended host configurations](https://github.com/higoarm/1proxy2Xvpn/blob/main/docs/PERFORMANCE.md#recommended-host-configurations) in `docs/PERFORMANCE.md`.

---

## Quick Start

```bash
# 1. Clone and enter directory
git clone https://github.com/higoarm/1proxy2Xvpn.git
cd 1proxy2Xvpn

# 2. (Optional) Install the CLI globally so you can call it as `1proxy2xvpn`
#    from anywhere. If you skip this, run it as `./1proxy2xvpn` from the
#    project directory (as shown in all examples below).
sudo ln -sf "$(pwd)/1proxy2xvpn" /usr/local/bin/1proxy2xvpn

# 3. Run setup (installs Docker, HAProxy, tunes kernel)
sudo ./1proxy2xvpn setup

# 4. Add your .ovpn files
cp /path/to/your/*.ovpn ovpns/

# 5. Build the image
./1proxy2xvpn build

# 6. Start all containers
./1proxy2xvpn up

# 7. Wait ~60s for VPNs to connect, then configure HAProxy
sudo ./1proxy2xvpn haproxy --only-up

# 8. Test — 10 requests should show rotating exit IPs
for i in {1..10}; do curl -s -x http://localhost:9999 https://api.ipify.org; echo; done
```

---

## CLI Reference

> Run the CLI as `./1proxy2xvpn` from the project directory. If you installed it
> globally (step 2 of Quick Start), you can drop the `./` and call `1proxy2xvpn`
> from anywhere.

```
./1proxy2xvpn setup                    Install dependencies, tune kernel, prepare host
./1proxy2xvpn build [--no-cache]       Build Docker image
./1proxy2xvpn up                       Start containers (one per .ovpn)
./1proxy2xvpn down                     Stop and remove all containers
./1proxy2xvpn destroy [--purge]        Tear down (--purge also removes image)

./1proxy2xvpn haproxy [--dry-run] [--only-up] [--public-stats]
                                     Generate haproxy.cfg from running containers

./1proxy2xvpn status [--json|--csv]    Show status of all containers
./1proxy2xvpn logs [container|all]     Stream logs
./1proxy2xvpn rotate [container|--burned]  Force IP rotation

./1proxy2xvpn blacklist add <name|ip>  Disable container in HAProxy rotation
./1proxy2xvpn blacklist remove <name|ip>  Restore container
./1proxy2xvpn blacklist list           List blacklisted containers
./1proxy2xvpn blacklist clear          Restore all

./1proxy2xvpn observability up         Start Prometheus + Grafana + cAdvisor (add `full` for logs)
./1proxy2xvpn observability down       Stop observability stack
```

---

## Architecture

```
                                    HOST MACHINE
 ┌────────────────────────────────────────────────────────────────────────────┐
 │                                                                            │
 │   Client ──► smart_router :9888 ──► HAProxy :9999 / :9998 (SOCKS5)        │
 │              (retry on 403/429)      │                                     │
 │                                      │  balance roundrobin + health check     │
 │            ┌──────────────┬──────────┴──────────┬──────────────┐          │
 │            │              │                     │              │          │
 │         :3100/3101    :3102/3103            :3104/3105     :310N          │
 │  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐          │
 │  │ tinyproxy  │  │ tinyproxy  │  │ tinyproxy  │  │ tinyproxy  │          │
 │  │  dante    │  │  dante    │  │  dante    │  │  dante    │          │
 │  │────────────│  │────────────│  │────────────│  │────────────│          │
 │  │   tun0     │  │   tun0     │  │   tun0     │  │   tun0     │          │
 │  │  OpenVPN   │  │  OpenVPN   │  │  OpenVPN   │  │  OpenVPN   │          │
 │  │────────────│  │────────────│  │────────────│  │────────────│          │
 │  │ Kill Switch│  │ Kill Switch│  │ Kill Switch│  │ Kill Switch│          │
 │  │  iptables  │  │  iptables  │  │  iptables  │  │  iptables  │          │
 │  └──────┬─────┘  └──────┬─────┘  └──────┬─────┘  └──────┬─────┘          │
 └─────────┼───────────────┼───────────────┼───────────────┼─────────────────┘
           │               │               │               │
        VPN IP 1        VPN IP 2        VPN IP 3        VPN IP N
        US               BR              DE              JP
           │               │               │               │
 ┌─────────┴───────────────┴───────────────┴───────────────┴─────────────────┐
 │                              INTERNET                                      │
 └────────────────────────────────────────────────────────────────────────────┘

 Observability sidecar (optional):
    Prometheus → Grafana (dashboards)
    Loki ← Promtail (container logs)
    Alertmanager → Discord/Slack/email
```

See `docs/ARCHITECTURE.md` for deep technical detail.

---

## Use Cases

| Use case | Description |
|---|---|
| Distributed IP rotation | Bypass rate limits without violating program scope |
| Brute-force testing | Authorized credential testing within program scope |
| User and resource enumeration | Large-scale ID/endpoint enumeration |
| IDOR discovery | Test object reference patterns from many sources |
| Geo-restriction validation | Verify access controls per region |
| WAF evasion research | Measure detection thresholds and bypass patterns |
| Business logic abuse testing | Race conditions, coupon reuse, etc. |
| Distributed crawling | Recon without per-IP throttling |
| API rate limit validation | Quantify defensive controls |
| Defensive analysis | Map detection patterns of production WAFs |

---

## Observability

Start the full stack:

```bash
./1proxy2xvpn observability up
```

Access:

- **Grafana**: <http://localhost:3000> (default credentials in `.env.example`)
- **Prometheus**: <http://localhost:9090>
- **Alertmanager**: <http://localhost:9093>

The pre-built dashboard shows:

- VPN pool health percentage
- Active containers count
- Requests per second
- 95th percentile latency
- CPU and memory per container
- Network throughput (TX/RX)
- VPN backend state over time

Alerts trigger on:

- HAProxy down (1m)
- More than 50% backends down (5m)
- High latency (>5s p95 for 5m)
- Host RAM below 10% (5m)
- File descriptor exhaustion (>85% for 5m)
- Container restart loops (5m)

---

## Integration with Security Tools

### Nuclei (HTTP scanning)

```bash
# HTTP templates via proxy (rotation)
nuclei -u target.com -proxy http://localhost:9999 \
  -type http \
  -exclude-tags proxy,fingerprint \
  -exclude-id tinyproxy-detect,squid-detect

# DNS/SSL/WHOIS — direct (no proxy)
nuclei -u target.com -type dns,ssl,whois
```

### Burp Suite / Caido

```
User options → Connections → Upstream Proxy Servers
  Destination host: *
  Proxy host: 127.0.0.1
  Proxy port: 9999 (HTTP) or 9998 (SOCKS5)
```

### ffuf

```bash
ffuf -u "https://target.com/FUZZ" \
     -w wordlist.txt \
     -x http://localhost:9999
```

### sqlmap (SQL injection)

```bash
# Route all sqlmap traffic through the HTTP proxy — each request rotates IPs,
# which helps avoid WAF rate-limits during injection testing.
sqlmap -u "https://target.com/item?id=1" \
       --proxy="http://localhost:9999" \
       -p id --batch --level 3 --risk 2

# For SOCKS5 (enable it first with ENABLE_SOCKS5=true on `up`):
sqlmap -u "https://target.com/item?id=1" \
       --proxy="socks5://localhost:9998" \
       -p id --batch
```

### nmap (port/service scanning)

nmap doesn't support HTTP proxies, but it can tunnel TCP connect scans through
the SOCKS5 endpoint. Enable SOCKS5 first (`ENABLE_SOCKS5=true ./1proxy2xvpn up`):

```bash
# TCP connect scan through the rotating SOCKS5 pool
nmap -sT -Pn -p 80,443,8080,8443 \
     --proxies socks5://localhost:9998 \
     target.com

# Service/version detection through the proxy
nmap -sT -Pn -sV -p 443 \
     --proxies socks5://localhost:9998 \
     target.com
```

> Note: `--proxies` only works with TCP connect scans (`-sT`). SYN scans
> (`-sS`), UDP, and OS detection bypass the proxy and are not routed through
> the VPN pool.

### Smart router (auto-retry on 403/429)

```bash
# In a separate terminal:
pip install -r middleware/requirements.txt
python middleware/smart_router.py

# Then point tools at port 9888 instead of 9999
nuclei -u target.com -proxy http://localhost:9888 ...
```

See `docs/INTEGRATIONS.md` for full per-tool examples.

---

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — Deep technical architecture
- [`docs/PROVIDERS.md`](docs/PROVIDERS.md) — Setup per VPN provider (ExpressVPN, PIA, NordVPN, Mullvad)
- [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) — Tuning for 10 / 100 / 500 / 1000 containers
- [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md) — Tool-by-tool examples
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — Complete error catalog
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — How to contribute

---

## Production deployment

For long-running deployments, use the included systemd units:

```bash
sudo cp -r . /opt/1proxy2xvpn
sudo cp systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now 1proxy2xvpn.service
sudo systemctl enable --now 1proxy2xvpn-router.service
```

---

## Uninstall / complete removal

The `uninstall` command removes everything the tool installs or creates —
containers, the observability stack, the Docker image and volumes, system
files (sysctl, modules-load, the `limits.conf` block, the global symlink),
systemd units, and the config/credentials in `~/.config/1proxy2xvpn`. It
restores your original `/etc/haproxy/haproxy.cfg` from the backup it made.

```bash
# Interactive — asks for confirmation, preserves your .ovpn files and the project dir
sudo ./1proxy2xvpn uninstall

# Non-interactive (assume yes to the confirmation prompt)
sudo ./1proxy2xvpn uninstall --yes

# Also delete ~/.config/1proxy2xvpn AND the project directory (incl. ovpns/)
sudo ./1proxy2xvpn uninstall --purge
```

**Preserved by default:** your `.ovpn` files and the project directory. Use
`--purge` only if you want those gone too (it asks you to type `DELETE` to
confirm).

**Not removed automatically** (shared system packages that other software may
use — remove manually only if you're sure they're unused):

```bash
sudo apt-get remove docker.io      # Docker
sudo apt-get remove haproxy        # HAProxy
```

Kernel tuning applied by `setup` lives in `/etc/sysctl.d/99-1proxy2xvpn.conf`,
which `uninstall` deletes; the tuning fully reverts on the next reboot.

If you prefer to remove things by hand instead of using the command, see the
step-by-step manual removal in
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md#manual-uninstall).

---

## License

MIT — see [LICENSE](LICENSE).

---

## Security disclosure

To report a security vulnerability privately, please open a
[GitHub security advisory](https://github.com/higoarm/1proxy2Xvpn/security/advisories/new)
or contact the maintainer directly rather than opening a public issue. Please
do not disclose the details publicly until a fix is available.
