# 1proxy2Xvpn

> **One proxy container per VPN connection** — Run dozens of isolated HTTP proxies, each tunneled through a different OpenVPN server, with a built-in Kill Switch and HAProxy load balancing.

```
curl → HAProxy :9999 → tinyproxy :3128 → tun0 (OpenVPN) → VPN IP → Internet
                              ↑
                    eth0 blocked by Kill Switch
```

---

## Features

- **One container per VPN** — each container connects to a different `.ovpn` file
- **Kill Switch** — if the VPN drops, all traffic is immediately blocked (no IP leaks)
- **tinyproxy** — lightweight HTTP/HTTPS proxy (CONNECT method supported)
- **Auto-routing** — all traffic is forced through `tun0`, including DNS
- **HAProxy integration** — single entry point that rotates across all VPN IPs
- **Health check monitoring** — auto-restarts tinyproxy or OpenVPN if they crash
- **Dynamic config generation** — no manual editing when adding/removing VPNs

---

## Use Cases

> ⚠️ **This tool is intended for authorized security testing, research, and educational purposes only. Always obtain explicit written permission before testing any system you do not own. Unauthorized use may violate local and international laws.**

| Use Case | Description |
|---|---|
| **Distributed IP rotation** | Bypass rate limits by rotating exit IPs across requests, preventing single-source throttling |
| **Brute-force testing** | Distribute authentication attempts across multiple IPs within authorized penetration test scope |
| **User and resource enumeration** | Perform large-scale enumeration of users, endpoints, or resources without triggering IP-based blocks |
| **IDOR discovery at scale** | Test Insecure Direct Object Reference vulnerabilities across large ID ranges from distributed sources |
| **Geo-restriction bypass** | Access region-locked content and validate geo-based access controls during security assessments |
| **WAF and anti-bot evasion** | Evaluate the effectiveness of Web Application Firewalls and bot detection mechanisms |
| **Business logic abuse testing** | Test race conditions, coupon reuse, loyalty point manipulation, and other logic flaws at scale |
| **Distributed web crawling** | Crawl and fuzz large web applications without hitting per-IP request limits |
| **API abuse and limit testing** | Assess public API rate limiting, quota enforcement, and abuse prevention controls |
| **Credential stuffing** | Simulate credential stuffing attacks in controlled, authorized environments to validate defensive controls |
| **Defensive mechanism analysis** | Map and measure rate limiting thresholds, blocking behavior, and detection response times |

---

## Requirements

- Docker Engine 20.10+
- HAProxy 2.x (for multi-proxy load balancing)
- Linux host with `/dev/net/tun` support
- `.ovpn` configuration files (ExpressVPN, NordVPN, ProtonVPN...)

---

## Hardware Recommendations

Each container runs **OpenVPN** (with active encryption) + **tinyproxy** simultaneously. Resource usage scales linearly with the number of containers and proportionally with traffic volume.

### Resource usage per container

| Resource | Idle | Under load |
|---|---|---|
| CPU | ~0.5% of 1 core | ~1–2% of 1 core |
| RAM | ~30–50 MB | ~50–80 MB |
| Disk | ~5 MB (runtime) | ~5 MB |
| Network | ~5–15 Kbps | Up to VPN server speed |

### Minimum recommended spec by container count

#### Up to 20 containers
```
CPU  : 2 cores
RAM  : 4 GB
Disk : 20 GB SSD
Net  : 100 Mbps
```

#### Up to 50 containers
```
CPU  : 4 cores
RAM  : 8 GB
Disk : 40 GB SSD
Net  : 200 Mbps
```

#### Up to 100 containers
```
CPU  : 8 cores
RAM  : 16 GB
Disk : 60 GB SSD
Net  : 500 Mbps
```

#### Up to 200 containers
```
CPU  : 12–16 cores
RAM  : 32 GB
Disk : 100 GB SSD
Net  : 1 Gbps
```

> **Network is the real bottleneck.** Each container is limited by its remote VPN server speed. Running many containers under heavy load can saturate your uplink quickly.

### Monitor resource usage in real time

```bash
# Live stats for all containers
docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"

# Top 10 highest CPU consumers
docker stats --no-stream \
  --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" \
  | sort -t$'\t' -k2 -rh | head -10

# Check system memory pressure
free -h

# Check if system is using swap (sign of insufficient RAM)
vmstat 1 3
```

### Increase system limits for large deployments

When running 100+ containers, apply these kernel tuning settings:

```bash
# Increase inotify limits (prevents "Too many open files" warnings in HAProxy)
echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.conf
echo "fs.inotify.max_user_instances=512"  | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

## Project Structure

```
1proxy2Xvpn/
│
├── docker/                        ← Container build files (internal)
│   ├── Dockerfile
│   ├── tinyproxy.conf
│   ├── entrypoint.sh
│   └── iptables_killswitch.sh
│
├── ovpns/                         ← Place your .ovpn files here
│   └── .gitkeep
│
├── 1-build.sh                     ← Step 1: build the Docker image
├── 2-start_containers.sh          ← Step 2: start all VPN containers
├── 3-generate_haproxy.sh          ← Step 3: generate HAProxy config
├── 4-status_proxies.sh            ← Step 4: check status of all proxies
│
├── docker-compose.yml             ← Single container example
├── .gitignore
└── README.md
```

> **Note:** The `docker/` directory contains the internal container files.
> You only need to interact with the numbered scripts in the root folder.

---

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/higoarm/1proxy2Xvpn.git
cd 1proxy2Xvpn
```

### 2. Grant execution permission to all scripts

```bash
chmod +x *.sh
```

> ⚠️ **This step is required.** Without it, the scripts will return a `Permission denied` error when executed.

### 3. Add your `.ovpn` files

```bash
cp /path/to/your/files/*.ovpn ovpns/
```

### 4. Install HAProxy

```bash
sudo apt-get update && sudo apt-get install -y haproxy
```

---

## Usage — Step by Step

### Step 1 — Build the Docker image

```bash
./1-build.sh
```

### Step 2 — Start all containers

```bash
# One container per .ovpn file, ports starting at 3100
./2-start_containers.sh

# Custom folder and start port
./2-start_containers.sh ./ovpns 4000
```

> **Note:** This script automatically removes **all** existing Docker containers before starting, preventing port conflicts and name collisions — the most common cause of startup failures.

### Step 3 — Generate HAProxy config

```bash
sudo ./3-generate_haproxy.sh

# Preview without applying
./3-generate_haproxy.sh --dry-run

# Only include containers with active VPN
sudo ./3-generate_haproxy.sh --only-up
```

### Step 4 — Check status

```bash
./4-status_proxies.sh

# Increase timeout for slow VPNs
./4-status_proxies.sh 15
```

Example output:
```
CONTAINER                                PORT     STATUS         VPN IP
─────────────────────────────────────────────────────────────────────────
Example1                                 :3100    ✓ UP           49.67.96.XX
Example2                                 :3101    ✓ UP           113.244.55.XX
Example3                                 :3102    ⟳ CONNECTING   waiting for VPN...
```

### Test the proxies

```bash
# Direct — specific container
curl -x http://localhost:3100 https://ifconfig.me

# Via HAProxy — rotates VPN IP on each request
curl -x http://localhost:9999 https://ifconfig.me
curl -x http://localhost:9999 https://ifconfig.me
curl -x http://localhost:9999 https://ifconfig.me

# Continuous rotation test
while true; do curl -x "http://localhost:9999" "icanhazip.com"; sleep 1; done
```

### HAProxy stats dashboard

```
URL:      http://localhost:9998
User:     haproxy
Password: haproxy
```

---

## Architecture

Each `.ovpn` file becomes an isolated container with its own VPN tunnel and Kill Switch. HAProxy distributes incoming requests across all of them, rotating the exit IP on every request.

```
                                    HOST MACHINE
 ┌────────────────────────────────────────────────────────────────────────────────┐
 │                                                                                │
 │   Client ──────────────────────────► HAProxy :9999                            │
 │                                       balance random                           │
 │                                              │                                │
 │        ┌──────────┬──────────┬──────────┬────┴─────┬──────────┬──────────┐   │
 │        │          │          │          │          │          │          │   │
 │      :3100      :3101      :3102      :3103      :3104      :3105      :3106  │
 │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌──────┐ │
 │  │  tiny  │ │  tiny  │ │  tiny  │ │  tiny  │ │  tiny  │ │  tiny  │ │ ...  │ │
 │  │ proxy  │ │ proxy  │ │ proxy  │ │ proxy  │ │ proxy  │ │ proxy  │ │      │ │
 │  │────────│ │────────│ │────────│ │────────│ │────────│ │────────│ │:3107 │ │
 │  │  tun0  │ │  tun0  │ │  tun0  │ │  tun0  │ │  tun0  │ │  tun0  │ │:3108 │ │
 │  │OpenVPN │ │OpenVPN │ │OpenVPN │ │OpenVPN │ │OpenVPN │ │OpenVPN │ │:3109 │ │
 │  │────────│ │────────│ │────────│ │────────│ │────────│ │────────│ │      │ │
 │  │  Kill  │ │  Kill  │ │  Kill  │ │  Kill  │ │  Kill  │ │  Kill  │ │ same │ │
 │  │ Switch │ │ Switch │ │ Switch │ │ Switch │ │ Switch │ │ Switch │ │ pat. │ │
 │  └───┬────┘ └───┬────┘ └───┬────┘ └───┬────┘ └───┬────┘ └───┬────┘ └──┬───┘ │
 └──────┼──────────┼──────────┼──────────┼──────────┼──────────┼─────────┼─────┘
        │          │          │          │          │          │         │
     VPN IP 1   VPN IP 2   VPN IP 3   VPN IP 4   VPN IP 5   VPN IP 6  VPN IPs
    US :3100   BR :3101   DE :3102   JP :3103   AU :3104   GB :3105   7–10 ...
        │          │          │          │          │          │         │
 ┌──────┴──────────┴──────────┴──────────┴──────────┴──────────┴─────────┴──────┐
 │                                   INTERNET                                    │
 └───────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  Every request through HAProxy :9999 exits from a DIFFERENT VPN IP.        │
  │  eth0 outbound is BLOCKED on ALL containers (Kill Switch active).           │
  │  If any VPN drops → iptables blocks all traffic → zero IP leak.            │
  └─────────────────────────────────────────────────────────────────────────────┘
```

---

## Kill Switch Behavior

The Kill Switch is applied via `iptables` **before** OpenVPN starts:

| Traffic | Rule |
|---|---|
| Loopback (`lo`) | ✅ ALLOWED |
| → VPN server (IP:port) | ✅ ALLOWED (to establish tunnel) |
| → DNS bootstrap (1.1.1.1, 8.8.8.8) | ✅ ALLOWED (hostname resolution) |
| → `tun0` interface (VPN) | ✅ ALLOWED |
| Incoming port 3128 (tinyproxy) | ✅ ALLOWED |
| Everything else (`eth0` outbound) | ❌ BLOCKED |

---

## VPN with Credentials

If your `.ovpn` requires a username and password:

```bash
echo "your_username" > ovpns/auth.txt
echo "your_password" >> ovpns/auth.txt
chmod 600 ovpns/auth.txt
```

Add to your `.ovpn` file:
```
auth-user-pass /ovpn/auth.txt
```

---

## Troubleshooting

**All containers fail to start**
```bash
# Remove all existing containers and retry
docker rm -f $(docker ps -aq)
./2-start_containers.sh
```

**Container exits immediately**
```bash
docker logs container-name
```

**`tun0` not appearing after 90s**
```bash
docker exec container-name cat /var/log/openvpn.log
```

**Check Kill Switch rules**
```bash
docker exec container-name iptables -L -n -v
```

**Verify traffic goes through VPN**
```bash
curl -x http://localhost:3100 https://ifconfig.me
# Must return VPN IP, not your real IP
```

**`Too many open files` warning in HAProxy**
```bash
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512
sudo ./3-generate_haproxy.sh
```

---

## License

MIT License — free to use, modify and distribute.
