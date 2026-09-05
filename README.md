<h1 align="center">1proxy2Xvpn</h1>

<p align="center">
  <b>Distributed HTTP/SOCKS5 Proxy Infrastructure over OpenVPN</b><br>
  One isolated container per OpenVPN tunnel · hardened Kill Switch · round-robin IP rotation · optional observability
</p>

<p align="center">
  <a href="https://github.com/higoarm/1proxy2Xvpn/actions/workflows/ci.yml"><img src="https://github.com/higoarm/1proxy2Xvpn/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/higoarm/1proxy2Xvpn/actions/workflows/security.yml"><img src="https://github.com/higoarm/1proxy2Xvpn/actions/workflows/security.yml/badge.svg" alt="Security Scan"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/Platform-Linux-informational" alt="Platform: Linux">
  <img src="https://img.shields.io/badge/Docker-required-2496ED?logo=docker&logoColor=white" alt="Docker">
</p>

<p align="center">
  <code>Client → smart_router → HAProxy :9999 → tinyproxy :3128 → tun0 (OpenVPN) → VPN IP → Internet</code>
</p>

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## About

**1proxy2Xvpn** turns your commercial VPN subscription into a fleet of rotating
proxy endpoints. It takes the `.ovpn` configuration files from providers like
**ExpressVPN, NordVPN, Surfshark, Private Internet Access (PIA), Mullvad** — or
any provider that offers standard OpenVPN configs — and runs each one in its own
isolated Docker container. A single HAProxy endpoint then load-balances across
all of them, so every request you send exits through a different VPN IP.

If your VPN provider gives you `.ovpn` files, this tool turns them into a
distributed proxy pool. Point any tool at `http://localhost:9999` and your
traffic round-robins across every VPN location you've configured — one IP after
another, cycling through the whole pool before any address repeats.

It was built for **authorized security testing at scale** — Bug Bounty programs,
Vulnerability Disclosure Programs, and sanctioned penetration tests — where you
need IP diversity to avoid per-IP rate limits without ever leaking your real
address. Every container boots behind a deny-by-default `iptables` Kill Switch,
so if a tunnel drops, traffic stops instead of falling back to your real IP.

**Works with any OpenVPN-based provider**, including:

- ExpressVPN
- NordVPN
- Surfshark
- Private Internet Access (PIA)
- Mullvad

If it ships standard `.ovpn` files, it works.

Highlights:

- **Round-robin IP rotation** across hundreds of VPN exits from one endpoint
- **Hardened Kill Switch** — no `--privileged`, deny-by-default `iptables` (IPv4 + IPv6), DNS-leak prevention
- **HAProxy load balancing** with auto-generated config and regional pools
- **Optional observability** — Prometheus + Grafana + cAdvisor dashboards when you want them
- **One-command CLI** for the entire lifecycle, plus clean uninstall
- **Smart retry middleware** — auto-rotates on `403 / 429 / 451`

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## Demo

**Installation** — clone, setup, and build from a fresh machine:

<!-- UPLOAD-VIDEO-1: On GitHub, edit this file in the web editor and drag your
     installation .mp4 onto the line below. GitHub replaces this comment area
     with an embedded video player. -->


**IP rotation in action** — health check, then 10 requests each returning a
different exit IP through the VPN pool:

<!-- UPLOAD-VIDEO-2: Drag your IP-rotation .mp4 onto the line below in the
     GitHub web editor. -->


**HAProxy stats** — all VPN backends UP, load-balanced behind one endpoint:

<!-- SCREENSHOT-HAPROXY: Drag your HAProxy stats screenshot (.png) onto the line
     below in the GitHub web editor. Or commit it to docs/media/ and reference it
     as: ![HAProxy stats](docs/media/haproxy.png) -->


**Grafana dashboard** — live pool health, active containers, and throughput:

<!-- SCREENSHOT-GRAFANA: Drag your Grafana dashboard screenshot (.png) onto the
     line below in the GitHub web editor. Or commit it to docs/media/ and
     reference it as: ![Grafana dashboard](docs/media/grafana.png) -->


![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## Table of Contents

- [About](#about)
- [Demo](#demo)
- [Features](#features)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [CLI Reference](#cli-reference)
- [IP Rotation](#ip-rotation)
- [Bug Bounty Use Cases](#bug-bounty-use-cases)
- [Integration with Security Tools](#integration-with-security-tools)
- [Observability](#observability)
- [Ethical Use](#ethical-use)
- [Uninstall](#uninstall)
- [Documentation](#documentation)
- [License](#license)

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## Features

**Architecture & Security**
- One container per VPN endpoint — total isolation between tunnels
- Hardened containers — no `--privileged`, minimal Linux capabilities
- Kill Switch applied at boot — deny-by-default `iptables` before any service starts
- IPv6 fully blocked — prevents leaks outside the IPv4-only tunnel
- DNS-leak prevention — hostnames pre-resolved, no bootstrap DNS path
- HTTP + optional SOCKS5 per container (tinyproxy + dante-server)
- Anti-fingerprint — sanitized error pages, identifying headers stripped

**Operations**
- Unified `1proxy2xvpn` CLI for the whole lifecycle
- Auto-discovery — HAProxy config regenerated from running containers
- Semantic health checks — HAProxy verifies the tunnel actually works (dead tunnels leave rotation)
- OpenVPN auto-restart — a dropped tunnel is relaunched automatically inside the container
- Regional pools — automatic grouping by country code in the filename
- Blacklist API — disable burned IPs without restarting the fleet
- Smart retry middleware — automatic IP rotation on `403 / 429 / 451`
- Clean, complete uninstall

**Observability (optional)**
- Not required to run the tool — enable only if you want a metrics dashboard
- Prometheus metrics — per container, HAProxy, host
- Grafana dashboards — throughput, latency, pool health out of the box
- cAdvisor — per-container CPU/memory/network
- Optional full stack — Loki logs + Alertmanager alerting

**DevSecOps**
- CI pipelines — shellcheck, hadolint, yamllint, ruff
- Security scans — Trivy (CVEs), Gitleaks (secrets) on every push
- Multi-arch builds — amd64 + arm64 via GitHub Actions

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## Architecture

```
                                    HOST MACHINE
 +--------------------------------------------------------------------------+
 |                                                                          |
 |   Client --> smart_router :9888 --> HAProxy :9999 / :9998 (SOCKS5)       |
 |              (retry on 403/429)     |                                    |
 |                                     |  balance roundrobin + healthchecks |
 |            +--------------+---------+-----------+--------------+          |
 |         :20000/...     :20001/...          :20002/...     :2000N          |
 |  +------------+  +------------+  +------------+  +------------+           |
 |  | tinyproxy  |  | tinyproxy  |  | tinyproxy  |  | tinyproxy  |           |
 |  |  (+ dante) |  |  (+ dante) |  |  (+ dante) |  |  (+ dante) |           |
 |  |  tun0 VPN  |  |  tun0 VPN  |  |  tun0 VPN  |  |  tun0 VPN  |           |
 |  | KillSwitch |  | KillSwitch |  | KillSwitch |  | KillSwitch |           |
 |  +-----+------+  +-----+------+  +-----+------+  +-----+------+           |
 +--------+---------------+---------------+---------------+------------------+
       VPN IP 1        VPN IP 2        VPN IP 3        VPN IP N
          +---------------+------> INTERNET <------+---------------+
```

Full technical deep-dive in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## Requirements

| Component | Minimum |
|-----------|---------|
| OS | Linux kernel 5.x |
| CPU | 4 cores |
| RAM | 8 GB |
| Disk | 40 GB SSD |
| Network | 100 Mbps |
| Docker | 20.10 |
| HAProxy | 2.4 |

> Hardware needs scale with the number of `.ovpn` files you run. For sizing at
> 100 / 300 / 500 / 1000+ containers, see the
> [recommended host configurations](https://github.com/higoarm/1proxy2Xvpn/blob/main/docs/PERFORMANCE.md#recommended-host-configurations)
> in `docs/PERFORMANCE.md`.

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## Quick Start

```bash
# 1. Clone and enter the directory
git clone https://github.com/higoarm/1proxy2Xvpn.git && cd 1proxy2Xvpn

# 2. Make the CLI executable
chmod +x 1proxy2xvpn scripts/*.sh docker/*.sh

# 3. Run setup (installs Docker, HAProxy, tunes the kernel)
sudo ./1proxy2xvpn setup

# 4. Apply your new docker group membership (needed on a fresh Docker install,
#    otherwise the next commands fail with a docker.sock permission error)
newgrp docker

# 5. Add your .ovpn files
cp /path/to/your/*.ovpn ovpns/

# 6. Build the image
./1proxy2xvpn build

# 7. Start all containers
./1proxy2xvpn up

# 8. Wait ~60s for VPNs to connect, then configure HAProxy
sudo ./1proxy2xvpn haproxy --only-up

# 9. Test — 10 requests should show rotating exit IPs
for i in {1..10}; do curl -s -x http://localhost:9999 https://api.ipify.org; echo; done
```

> On a machine where Docker was just installed, your user isn't in the `docker`
> group yet for the current shell. `newgrp docker` applies it immediately;
> alternatively, log out and back in. Without this, `build` and `up` fail with
> `permission denied ... docker.sock`.

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## CLI Reference

> Run the CLI as `./1proxy2xvpn` from the project directory.

```
./1proxy2xvpn setup                     Install dependencies, tune kernel, prepare host
./1proxy2xvpn build [--no-cache]        Build the Docker image
./1proxy2xvpn up                        Start containers (one per .ovpn)
./1proxy2xvpn down                      Stop and remove all containers
./1proxy2xvpn destroy [--purge]         Tear down everything (--purge also removes the image)

./1proxy2xvpn haproxy [--only-up]       Generate haproxy.cfg from running containers
./1proxy2xvpn proxychains [--install]   Generate proxychains.conf (SOCKS5 rotation for nmap/hydra)
./1proxy2xvpn status [--json|--csv]     Show the status of all containers
./1proxy2xvpn logs [container] [-f]     Show logs (add -f to follow live)
./1proxy2xvpn rotate [container]        Force IP rotation

./1proxy2xvpn blacklist add <name|ip>   Disable a container in the HAProxy rotation
./1proxy2xvpn blacklist remove <name>   Restore a container
./1proxy2xvpn blacklist list            List blacklisted containers
./1proxy2xvpn blacklist clear           Restore all

./1proxy2xvpn observability up [full|portainer]
                                        (Optional) Start metrics dashboard / container UI
./1proxy2xvpn observability down        Stop the observability stack

./1proxy2xvpn uninstall [--yes|--purge] Remove 1proxy2Xvpn from the host completely
./1proxy2xvpn version                   Print version
```

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## IP Rotation

HAProxy uses `balance roundrobin` across every backend, so connections cycle
through all VPN exits in order — every IP is used once before any repeats. This
maximizes IP diversity and avoids the accidental repeats a random algorithm
produces.

```bash
for i in {1..10}; do curl -s -x http://localhost:9999 https://api.ipify.org; echo; done
```

Rotation happens **per new connection**. A tool that reuses one keep-alive
connection for many requests keeps that connection's IP for its lifetime —
disable keep-alive client-side for strict per-request rotation.

Force a fresh IP on a specific container, or pull a burned IP out of the pool:

```bash
./1proxy2xvpn rotate <container>            # reconnect -> new IP
./1proxy2xvpn blacklist add <container>     # remove from rotation
./1proxy2xvpn blacklist remove <container>  # restore
```

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## Bug Bounty Use Cases

The IP diversity provided by the pool maps directly onto common Bug Bounty and
authorized-testing needs. All of the below assume you have **explicit permission**
to test the target (see [Ethical Use](#ethical-use)).

| Use case | How the tool helps |
|---|---|
| **IP ban bypass** | When a target blocks your address, requests keep flowing through the other VPN exits — a banned IP is a single container you can `blacklist` and skip. |
| **Rate-limit bypass** | Per-IP throttling is spread across N exits, so the aggregate throughput multiplies while each individual IP stays under the limit. |
| **Automatic IP rotation in recon pipelines** | Point your recon chain at `http://localhost:9999`; every connection round-robins to a fresh IP with no manual switching. |
| **Vulnerability scanning (Nuclei) with rotating IPs** | Run Nuclei through the proxy so template checks come from many IPs, reducing WAF detection and per-IP blocks. |
| **Directory/parameter brute-force (ffuf, dirsearch, gobuster)** | High-volume fuzzing distributes across the pool, avoiding the per-IP rate walls that normally throttle brute-force. |
| **SQL injection testing (sqlmap) with rotating IPs** | Route sqlmap via the HTTP proxy so injection payloads originate from varied IPs during long runs. |
| **High-scale parallel scanning with distinct IPs** | Launch many parallel workers, each exiting through a different VPN IP for wide, fast coverage. |
| **Nmap via SOCKS5 (TCP connect scans)** | Tunnel `nmap -sT` through the SOCKS5 endpoint with proxychains to scan from a VPN exit instead of your real address. |
| **Distributed authentication brute-force (Hydra)** | Spread credential attempts across multiple IPs (via SOCKS5/proxychains) to avoid single-IP lockouts. |

> Concrete commands for each tool are in
> [Integration with Security Tools](#integration-with-security-tools) and
> [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md).

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## Integration with Security Tools

### Nuclei
```bash
nuclei -u target.com -proxy http://localhost:9999 -type http
```

### ffuf
```bash
ffuf -u "https://target.com/FUZZ" -w wordlist.txt -x http://localhost:9999
```

### dirsearch / gobuster
```bash
# dirsearch (HTTP proxy)
dirsearch -u https://target.com --proxy http://localhost:9999

# gobuster (HTTP proxy)
gobuster dir -u https://target.com -w wordlist.txt --proxy http://localhost:9999
```

### sqlmap
```bash
sqlmap -u "https://target.com/item?id=1" \
       --proxy="http://localhost:9999" -p id --batch --level 3 --risk 2
```

### nmap
nmap's own `--proxies` flag only supports HTTP and SOCKS4 (not SOCKS5), and it's
an incomplete feature that doesn't cover ping/port-scan phases. The reliable way
to route nmap through the SOCKS5 pool is **proxychains**, which speaks SOCKS5
natively. The tool generates a ready-to-use `proxychains.conf` for you (with all
your SOCKS5 proxies and per-connection rotation) — just like it does for HAProxy:

```bash
# Bring containers up with SOCKS5 enabled, then generate the config
ENABLE_SOCKS5=true ./1proxy2xvpn up
./1proxy2xvpn proxychains          # writes ./proxychains.conf

# Run TCP connect scans through it (rotates IP per connection)
proxychains4 -f proxychains.conf nmap -sT -Pn -p 80,443,8080,8443 target.com
```

Install it system-wide to drop the `-f` flag:
```bash
sudo ./1proxy2xvpn proxychains --install
proxychains4 nmap -sT -Pn -p 80,443 target.com
```
> Only TCP connect scans (`-sT -Pn`) work through a proxy. SYN (`-sS`), UDP, and
> OS detection bypass the proxy and are not routed through the VPN pool — this is
> a limitation of scanning over any proxy, not of this tool.

### Hydra (via SOCKS5 / proxychains)
Hydra has no native proxy flag, so route it through the generated
`proxychains.conf` (enable SOCKS5 first, then generate the config):
```bash
ENABLE_SOCKS5=true ./1proxy2xvpn up
./1proxy2xvpn proxychains
proxychains4 -f proxychains.conf hydra -L users.txt -P passwords.txt \
  target.com http-post-form "/login:user=^USER^&pass=^PASS^:Invalid"
```

### Burp Suite / Caido
```
Settings -> Network -> Upstream Proxy
  Destination host: *
  Proxy host: 127.0.0.1
  Proxy port: 9999 (HTTP) or 9998 (SOCKS5)
```

### Smart router — auto-retry with IP rotation (HTTP + HTTPS)
The smart router sits in front of HAProxy on `:9888` and automatically retries
requests that come back `403 / 429 / 451 / 503`, each retry over a **fresh
upstream connection** so a different VPN IP is used every time. It handles both
plain HTTP and **HTTPS (CONNECT tunneling)**, so it works with Burp, sqlmap,
ffuf, nuclei, and httpx against HTTPS targets — and each HTTPS tunnel exits
through a different IP.

```bash
# Optional: metrics endpoint needs prometheus_client (the proxy itself needs
# nothing beyond Python 3's standard library)
pip install -r middleware/requirements.txt

# Run it (points at the HAProxy endpoint by default)
python3 middleware/smart_router.py --upstream http://127.0.0.1:9999 --listen 0.0.0.0:9888

# Then point any tool at :9888 instead of :9999
nuclei  -u https://target.com -proxy http://localhost:9888
sqlmap  -u "https://target.com/item?id=1" --proxy="http://localhost:9888" --batch
```
Metrics are exposed at `http://localhost:9888/metrics` (Prometheus format).

See [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md) for full per-tool examples.

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## Observability

> **Completely optional.** The core tool — starting proxies, IP rotation, the
> Kill Switch — works fully **without** this stack. Prometheus and Grafana are
> only for a visual metrics dashboard when you want it. For a quick health check,
> `./1proxy2xvpn status` already lists every container, its exit IP, and health —
> no monitoring stack needed. Skip this section unless you specifically want
> long-term graphs.

If you do want the dashboard:

```bash
./1proxy2xvpn observability up            # lite: Prometheus + Grafana + cAdvisor
./1proxy2xvpn observability up full       # adds Loki (logs) + Alertmanager (alerts)
./1proxy2xvpn observability up portainer  # also start Portainer (container UI)
```

- **Grafana** — <http://localhost:3000> (`admin` / `changeme`) — the dashboards
- **Prometheus** — <http://localhost:9090> — collects and stores the metrics that
  Grafana graphs (it's the data store; Grafana is the viewer)
- **Portainer** — <https://localhost:9444> — optional container-management UI
  (the admin password is set automatically and printed on start)

The bundled *1proxy2Xvpn — Overview* dashboard shows pool health, active
containers, connections/sec, per-container CPU/memory, and network throughput.
`observability up` waits for Grafana to become ready and prints the URL when it
is, so you don't hit the port before it's live. Tear it all down with
`./1proxy2xvpn observability down`.

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## Ethical Use

This tool is intended **exclusively for authorized security testing**: Bug Bounty
programs (HackerOne, Intigriti, Bugcrowd), Vulnerability Disclosure Programs
(VDP), authorized penetration tests, and academic research with proper consent.

**Never test systems you do not own or have explicit written permission to
assess.** Unauthorized use may violate computer-crime laws in your jurisdiction.

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## Uninstall

```bash
sudo ./1proxy2xvpn uninstall            # interactive, preserves your .ovpn files
sudo ./1proxy2xvpn uninstall --yes      # non-interactive
sudo ./1proxy2xvpn uninstall --purge    # also delete config + project directory
```

Removes all containers, the observability stack, the Docker image and volumes,
system files (sysctl, modules-load, the `limits.conf` block, the global
symlink), and `~/.config/1proxy2xvpn` — and restores your original
`/etc/haproxy/haproxy.cfg` from backup. Shared packages (`docker.io`, `haproxy`)
are left installed. Step-by-step manual removal is in
[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md#manual-uninstall).

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — Technical deep-dive
- [`docs/PROVIDERS.md`](docs/PROVIDERS.md) — Per-provider setup (ExpressVPN, PIA, NordVPN, Mullvad)
- [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) — Tuning for 10 / 100 / 500 / 1000 containers
- [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md) — Tool-by-tool examples
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — Complete error catalog
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — How to contribute

![](https://raw.githubusercontent.com/andreasbm/readme/master/assets/lines/aqua.png)

## License

Distributed under the MIT License. See [LICENSE](LICENSE) for details.
