# Performance Tuning Guide

How to size, deploy, and tune `1proxy2Xvpn` from 10 to 1000+ containers.

---

## Resource budget per container

Measured on Ubuntu 22.04, kernel 5.15, OpenVPN 2.6, AES-256-GCM:

| Metric | Idle | Light load (10 req/s) | Heavy load (100 req/s) |
|--------|------|----------------------|-----------------------|
| CPU | 0.5% of 1 core | 2-3% | 8-12% |
| RAM | 30-50 MB | 50-70 MB | 70-100 MB |
| File descriptors | ~50 | ~200 | ~800 |
| Network (encrypted) | ~5 Kbps | ~50 Kbps | ~500 Kbps |
| Disk I/O | negligible | negligible | negligible |

These are **steady-state** values. Startup spikes (initial OpenVPN handshake) consume more CPU briefly.

---

## Recommended host configurations

### 10 containers

```
CPU       : 2 cores
RAM       : 4 GB
Disk      : 20 GB SSD
Network   : 100 Mbps
OS        : Linux kernel 5.x+
```

Sufficient for personal Bug Bounty research. Light Nuclei scans, individual ffuf runs.

### 50 containers

```
CPU       : 4 cores
RAM       : 8 GB
Disk      : 40 GB SSD
Network   : 250 Mbps
```

Most professional individual operators use this tier. Comfortable for daily scanning workloads.

### 100 containers

```
CPU       : 8 cores
RAM       : 16 GB
Disk      : 60 GB SSD
Network   : 500 Mbps
```

Suitable for small teams or heavy research. Some Bug Bounty hunters running automated platforms operate here.

### 300 containers

```
CPU       : 16 cores
RAM       : 32 GB
Disk      : 100 GB SSD
Network   : 1 Gbps
```

This is roughly the scale of the project author's own setup. Saturates a 1Gbps link under heavy scanning. Likely needs cloud or dedicated server hardware.

### 500+ containers

```
CPU       : 32+ cores (AMD EPYC or Xeon)
RAM       : 64 GB
Disk      : 200 GB NVMe SSD
Network   : 2.5-10 Gbps
```

Specialized deployments. Bandwidth becomes the primary cost driver.

### 1000+ containers

Single-host deployments above this scale show diminishing returns. Consider:

- **Horizontal scaling**: multiple hosts behind a federation HAProxy or DNS round-robin
- **Kubernetes**: each pod = one container, leverage cluster scheduler
- **Specialized hardware**: bare-metal with hardware AES offload (Intel AES-NI, AMD VAES)

---

## Kernel tuning

The setup script (`scripts/01_setup.sh`) applies these settings, but if tuning manually:

### `/etc/sysctl.d/99-1proxy2xvpn.conf`

```ini
# File descriptors — needed for high container count
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# IP forwarding (required for NAT)
net.ipv4.ip_forward = 1

# TCP backlog (avoid SYN drops under load)
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# Connection tracking (each container has its own conntrack table,
# but the host's table fills up with NAT entries for forwarded traffic)
net.netfilter.nf_conntrack_max = 1048576

# TCP buffer tuning for high-bandwidth multi-stream workloads
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
```

Apply: `sudo sysctl -p /etc/sysctl.d/99-1proxy2xvpn.conf`

### `/etc/security/limits.conf`

```
*  soft  nofile  65536
*  hard  nofile  1048576
```

### Docker daemon limits

`/etc/docker/daemon.json`:

```json
{
  "default-ulimits": {
    "nofile": {
      "name": "nofile",
      "soft": 65536,
      "hard": 65536
    }
  },
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

Then `sudo systemctl restart docker`.

---

## HAProxy tuning

The generated `haproxy.cfg` includes sensible defaults. For very high scale (500+ containers):

```haproxy
global
    maxconn 200000          # default: 100000
    nbthread 16             # default: 8 — match physical core count
    cpu-map auto:1/1-16 0-15  # pin threads to specific cores
```

### Stats refresh interval

Default is 10s. For 500+ servers, increase to reduce browser load:

```haproxy
stats refresh 30s
```

---

## Docker tuning

### Daemon settings

For high container density, consider switching the storage driver to `overlay2` (already default on modern kernels):

```json
{
  "storage-driver": "overlay2"
}
```

### Image caching

Always reuse the same image tag. With 300 containers from the same image, each container shares the read-only layers — a single 80MB image footprint, regardless of container count.

### Restart policy

`--restart=on-failure:10` is used by default. For containers with persistently bad `.ovpn` files (auth errors), use:

```bash
1proxy2xvpn rotate --burned  # surface and auto-cleanup
```

---

## Network tuning

### MTU considerations

OpenVPN's default tunnel MTU is 1500, but the underlying network often has lower MTU after encryption overhead. If you see fragmentation:

Add to `.ovpn`:

```
tun-mtu 1400
mssfix 1360
```

### Concurrent connections per container

`tinyproxy.conf` (already in defaults):

```
MaxClients 500          # max connections per container
MinSpareServers 25      # always keep this many ready
MaxSpareServers 100
StartServers 50
```

For 300 containers × 500 max clients = **150,000 concurrent connections theoretically supported**, far beyond what most workloads will use.

### Bandwidth distribution

If your network is asymmetric (e.g., 1Gbps down / 100Mbps up), upstream-heavy workloads (uploads, large POST bodies) will bottleneck.

Use `iperf3` to measure each container's throughput periodically:

```bash
docker exec -it <container> iperf3 -c iperf.he.net -t 10
```

---

## Application-layer tuning

### Nuclei

Lower concurrency when running through proxy to give VPNs time to handle requests:

```bash
nuclei -u target.com -proxy http://localhost:9999 \
    -c 25 \              # template concurrency (default 25)
    -bulk-size 25 \      # hosts to scan in parallel
    -rate-limit 150      # max requests per second across all templates
```

### ffuf

Cap parallelism to avoid hammering the same VPN with bursts:

```bash
ffuf -u "https://target.com/FUZZ" -w wordlist.txt \
     -x http://localhost:9999 \
     -t 50                 # threads
```

### Burp Suite

Burp may saturate HAProxy with thousands of connections per second. Tune:

- **Active Scan++** → reduce concurrent requests to 20
- **User Options** → **Connections** → **Upstream Proxy** → use HAProxy URL
- **Project Options** → **HTTP** → **Connection** → enable keep-alive

---

## Monitoring during scaling

When running at scale, watch:

### From Grafana

- **VPN pool health** — should stay above 80%
- **p95 latency** — should stay below 3s
- **CPU per container** — should stay below 50% average

### From the command line

```bash
# Host load
watch -n 2 'free -h; echo; uptime; echo; ss -s'

# Per-container CPU/RAM
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"

# Connection count to HAProxy
ss -tn state established '( dport = :9999 )' | wc -l

# File descriptor usage
cat /proc/sys/fs/file-nr
# Output: <allocated> <unused> <max>
```

### Alerts to configure

Set Alertmanager (`observability/alertmanager/`) for:

- Host RAM < 20%
- File descriptors > 80% of max
- More than 30% of VPN pool DOWN
- HAProxy connection refusals

---

## Scaling beyond a single host

For deployments above 1000 containers, the limiting factor becomes:

1. **Public IP routing** — your host has one upstream, all VPN traffic egresses through it
2. **Memory pressure** — even at 50MB per container, 1000 containers = 50GB RAM
3. **Network conntrack** — the host kernel tracks every connection through `tun0` interfaces

Solutions:

### Multi-host with federation

Run `1proxy2xvpn` on multiple hosts, federate with a top-level HAProxy:

```
client → top-haproxy → [host-1 haproxy → 200 containers]
                    → [host-2 haproxy → 200 containers]
                    → [host-3 haproxy → 200 containers]
```

### Kubernetes

Each container becomes a pod with the same image. Use a `Service` of type `LoadBalancer` to expose tinyproxy. HAProxy or another L4 LB at the cluster edge.

Note: needs special handling for `/dev/net/tun` (`securityContext.capabilities`, `privileged: false`).

---

## Cost considerations

For Bug Bounty hunters, the per-month operational cost typically breaks down as:

| Item | Cost (USD/month) for 300-container setup |
|------|------------------------------------------|
| Dedicated server (32C/64GB/1Gbps) | $100-300 |
| ExpressVPN subscription | $8 |
| PIA subscription | $3 |
| Total | $111-311 |

Cloud equivalents (AWS, GCP) typically cost 3-5x more for similar bandwidth, primarily due to data egress charges. For sustained workloads, dedicated servers (Hetzner, OVH) are far more economical.

---

## Benchmarking your setup

After deployment, run this to baseline:

```bash
# Sustained throughput test (5 minutes, 100 concurrent connections)
for i in {1..100}; do
    curl -s -o /dev/null -x http://localhost:9999 -w "%{time_total}\n" \
        https://httpbin.org/get &
done
wait | sort -n | awk 'BEGIN{n=0;s=0} {a[n++]=$1; s+=$1} END {
    p95=a[int(n*0.95)]; p50=a[int(n*0.5)]; avg=s/n
    print "n="n " avg="avg " p50="p50 " p95="p95
}'
```

Expected ranges for a healthy setup:

- `avg`: 0.5–1.5s
- `p50`: 0.4–1.0s
- `p95`: 1.5–3.5s

If `p95` is above 5s, investigate slow VPNs and consider blacklisting them.
