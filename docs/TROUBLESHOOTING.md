# Troubleshooting

Comprehensive error catalog with diagnostic commands and fixes.

---

## Quick diagnostic

When in doubt, run this first:

```bash
echo "=== Docker ===" && docker --version && docker info 2>&1 | head -5
echo "=== HAProxy ===" && haproxy -v
echo "=== Image ===" && docker images 1proxy2xvpn
echo "=== /dev/net/tun ===" && ls -la /dev/net/tun
echo "=== Kernel TUN ===" && lsmod | grep tun
echo "=== Containers ===" && docker ps -a --filter "ancestor=1proxy2xvpn" --format "table {{.Names}}\t{{.Status}}" | head -10
echo "=== Disk ===" && df -h /var/lib/docker
echo "=== Memory ===" && free -h
echo "=== Listen ports ===" && ss -tlnp | grep -E ":(31[0-9]{2}|999[0-9]|808[45])" | head -5
```

---

## Installation issues

### `HAProxy not installed. Run: sudo ./1proxy2xvpn setup`

This means the `haproxy` binary is not on the system. Since v2.3.1, `setup`
installs packages one by one and **aborts with a clear error** if any critical
dependency (haproxy, docker, curl, openssl, ip) fails — so you should see the
real cause during setup rather than a silent failure.

Common causes and fixes:

```bash
# 1. Stale package index (most common on a fresh machine)
sudo apt-get update
sudo ./1proxy2xvpn setup

# 2. Install HAProxy manually to see the real apt error
sudo apt-get install haproxy
# e.g. "Unable to locate package" → enable the universe/extra repo first

# 3. Verify it's really there afterwards
haproxy -v
```

If `setup` printed `Setup could NOT install: haproxy ...`, follow the hints it
showed and re-run `sudo ./1proxy2xvpn setup`. Setup is idempotent — safe to run
as many times as needed.

### `docker: command not found`

```bash
sudo ./1proxy2xvpn setup
```

Or manually:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

### `Cannot connect to the Docker daemon`

Daemon not running:

```bash
sudo systemctl start docker
sudo systemctl enable docker
```

Or you're not in the `docker` group:

```bash
sudo usermod -aG docker $USER
# Log out and back in, OR:
newgrp docker
```

### `permission denied` on scripts

```bash
chmod +x 1proxy2xvpn scripts/*.sh docker/*.sh
```

---

## Container start failures

### All containers fail immediately

**Diagnose** by running one manually to see the real error:

```bash
docker run --rm \
    --cap-add=NET_ADMIN --cap-add=NET_RAW \
    --device /dev/net/tun:/dev/net/tun \
    --dns=1.1.1.1 \
    -p 3100:3128 \
    -v "$(pwd)/ovpns":/ovpn:ro \
    -w /ovpn \
    1proxy2xvpn:latest config.ovpn
```

#### Cause: `/dev/net/tun` missing

```bash
sudo modprobe tun
sudo mkdir -p /dev/net
sudo mknod /dev/net/tun c 10 200
sudo chmod 0666 /dev/net/tun
```

Make it persistent: `echo "tun" | sudo tee /etc/modules-load.d/tun.conf`

#### Cause: image rebuilt, old containers orphaned

```bash
./1proxy2xvpn down
./1proxy2xvpn up
```

The CLI's 2-layer cleanup handles this automatically.

#### Cause: port conflict

Another process is using one of the ports in the range:

```bash
ss -tlnp | grep ":31[0-9][0-9]"
```

Either kill the offending process or use a different `BASE_PORT` in `.env`.

#### Cause: image not built

```bash
docker images | grep 1proxy2xvpn
# If empty:
./1proxy2xvpn build
```

---

### Specific container fails: `AUTH_FAILED`

```bash
docker logs <container-name> 2>&1 | grep -i auth
```

Causes:
- Wrong credentials in `secrets/<name>.auth`
- Account suspended/expired with VPN provider
- Provider requires service-specific credentials, not account login (NordVPN, ProtonVPN)

Fix: regenerate credentials at the provider's site, update the auth file.

---

### Specific container fails: `Timeout waiting for tun0`

```bash
docker logs <container-name> | tail -30
```

Look for OpenVPN diagnostic output. Common causes:

| Log line | Cause | Fix |
|----------|-------|-----|
| `Connection refused` | Server port blocked by network | Try TCP variant of the `.ovpn` |
| `TLS Error: TLS key negotiation failed` | Certificate mismatch | Re-download `.ovpn` from provider |
| `Cannot resolve host` | DNS broken at boot | Restart container; check Docker DNS |
| `SIGTERM[soft,init_instance]` | Network drop during handshake | Retry; check host's internet |
| (no error, just hangs) | Server is offline | Try a different server |

---

### Specific container shows `CONNECTING` forever

```bash
./1proxy2xvpn logs <container-name>
```

If OpenVPN keeps reconnecting with timeouts, the VPN server is unreachable. Remove and rebuild:

```bash
docker rm -f <container-name>
./1proxy2xvpn up    # restarts only that one if .ovpn is still in ovpns/
```

If the issue persists with the same server, **remove the `.ovpn` from `ovpns/`** — it's a bad config:

```bash
mv ovpns/my_expressvpn_evpn_test_udp.ovpn /tmp/  # banished
```

---

## HAProxy issues

### `Port not found for <container>` warning during haproxy generation

The container is running but has no port mapped to host. Causes:

- Container was created without `-p` flag (legacy/manual)
- Container crashed mid-startup before port binding

```bash
docker inspect <container-name> | grep -A5 NetworkSettings.Ports
```

Fix by recreating: `./1proxy2xvpn down && ./1proxy2xvpn up`.

---

### `Failed to allocate directory watch: Too many open files`

This is a kernel inotify limit issue, not critical (HAProxy reloads anyway). Fix:

```bash
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512

# Persist:
echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.d/99-1proxy2xvpn.conf
echo "fs.inotify.max_user_instances=512" | sudo tee -a /etc/sysctl.d/99-1proxy2xvpn.conf
```

`scripts/01_setup.sh` already does this — re-run with `sudo ./1proxy2xvpn setup` if you skipped it.

---

### HAProxy won't reload — `socket bind failed`

Another HAProxy instance is using the ports:

```bash
sudo systemctl stop haproxy
sudo lsof -i :9999  # check what's using the port
sudo systemctl start haproxy
```

Or change `HAPROXY_FRONTEND_PORT` in `.env`.

---

### Stats panel password incorrect

The password is auto-generated and stored in `~/.config/1proxy2xvpn/credentials`:

```bash
cat ~/.config/1proxy2xvpn/credentials
```

If the file doesn't exist (first run never completed), regenerate:

```bash
rm -f ~/.config/1proxy2xvpn/credentials
sudo ./1proxy2xvpn haproxy   # will regenerate
```

---

## Proxy connection issues

### `curl: (7) Failed to connect to localhost port 9999`

HAProxy is not running. Check:

```bash
sudo systemctl status haproxy
```

Restart if needed:

```bash
sudo systemctl restart haproxy
```

Verify config is applied:

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```

---

### Some requests succeed, others return `502 Bad Gateway`

Some backends are unhealthy. Check stats:

```bash
curl -s -u "admin:$(grep HAPROXY_PASSWORD ~/.config/1proxy2xvpn/credentials | cut -d= -f2)" \
     "http://127.0.0.1:9997/;csv" | awk -F, '$2=="DOWN"' | head -10
```

Regenerate config including only working ones:

```bash
sudo ./1proxy2xvpn haproxy --only-up
```

---

### Returns my real IP, not VPN IP — **LEAK!**

This is critical. Stop everything:

```bash
./1proxy2xvpn down
```

Then investigate:

```bash
# Test single container manually
docker run -d --name leak-test \
    --cap-add=NET_ADMIN --cap-add=NET_RAW \
    --device /dev/net/tun:/dev/net/tun \
    -p 3199:3128 \
    -v "$(pwd)/ovpns":/ovpn:ro \
    -e HOST_IP="$(curl -s https://api.ipify.org)" \
    -w /ovpn \
    1proxy2xvpn:latest config.ovpn

# Wait 60s
sleep 60

# Check
curl -x http://localhost:3199 https://api.ipify.org

# Should NOT match:
curl https://api.ipify.org
```

If the leak persists, the new entrypoint (with `HOST_IP` env var) will **detect and kill the container** instead of letting it leak. The container will exit with error code 1.

Open a security advisory if you can reproduce this consistently — it's a critical bug.

---

### Connections timing out frequently

```bash
./1proxy2xvpn status
```

If many containers show `CONNECTING`, your network is unstable. Try:

```bash
# Increase timeout in the .env file
echo "TUN_WAIT_TIMEOUT=180" >> .env

# Restart containers
./1proxy2xvpn down && ./1proxy2xvpn up
```

---

## Performance issues

### Very slow responses (>10s)

Find slowest containers:

```bash
./1proxy2xvpn status --json | jq '.[] | select(.latency > 5) | "\(.name) \(.latency)s"'
```

Blacklist them:

```bash
./1proxy2xvpn blacklist add <slow-container-name>
```

---

### CPU pegged at 100%

Likely caused by:

1. **Too many containers for available cores** — `docker stats` to see per-container CPU
2. **OpenVPN encryption overhead** — particularly with AES-256 on hosts without AES-NI

```bash
# Check AES-NI support
grep -m1 aes /proc/cpuinfo

# If absent, use AES-128 in .ovpn (negotiate with provider) or switch to ChaCha20
```

3. **Conntrack table overflow** — kernel logs will show
```bash
dmesg | grep -i conntrack
```

Increase: `sudo sysctl -w net.netfilter.nf_conntrack_max=2097152`

---

### Out of memory (OOM kills)

```bash
dmesg | grep -i "out of memory"
```

Reduce container count or scale up host. Each container needs ~50MB RAM idle, up to 100MB under load.

---

## DNS issues

### DNS resolution slow or failing inside scans

Tools that resolve hostnames before sending requests (e.g., Nuclei DNS templates) need to bypass the proxy:

```bash
# WRONG (DNS goes via proxy, gets converted to HTTP error)
nuclei -u target.com -proxy http://localhost:9999 -type dns

# RIGHT
nuclei -u target.com -type dns    # no proxy for DNS
```

See `docs/INTEGRATIONS.md` for the full pattern.

---

### `getaddrinfo: Name or service not known` inside container

Container's `/etc/resolv.conf` is broken or DNS is being blocked by Kill Switch (it shouldn't be, but check):

```bash
docker exec <container-name> cat /etc/resolv.conf
docker exec <container-name> nslookup api.ipify.org
```

If failing, the container's `tun0` may not be properly routed. Restart it:

```bash
docker restart <container-name>
```

---

## Observability stack issues

### Grafana shows "no data"

1. Verify Prometheus is scraping HAProxy:
```bash
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {labels: .labels.job, health}'
```

2. Verify the HAProxy metrics endpoint is accessible:
```bash
curl http://localhost:8404/metrics | head -20
```

3. Check Prometheus logs:
```bash
docker logs 1p2v-prometheus | tail -20
```

---

### Loki shows "no logs"

Promtail needs to discover containers via Docker labels:

```bash
docker ps --filter "label=1proxy2xvpn.managed=true" | wc -l
```

If 0, the containers weren't started with the proper labels. Recreate:

```bash
./1proxy2xvpn down && ./1proxy2xvpn up
```

Check Promtail logs:

```bash
docker logs 1p2v-promtail | tail -30
```

---

### Alertmanager not sending notifications

Check the routing config:

```bash
docker exec 1p2v-alertmanager amtool config show
```

Common issues:
- Webhook URL invalid or rate-limited (Discord/Slack)
- SMTP credentials wrong (email)
- No active receivers configured

Default config has receivers commented out — uncomment and configure for your channel.

---

## Smart router issues

### Smart router won't start: `Address already in use`

Port 9888 is taken:

```bash
sudo lsof -i :9888
# or
ss -tlnp | grep 9888
```

Change in `.env`:

```
SMART_ROUTER_LISTEN=0.0.0.0:9889
```

---

### Smart router returns 502 on HTTPS

The smart router doesn't implement CONNECT method. Use HAProxy directly for HTTPS:

```bash
# HTTPS — use HAProxy on 9999
curl -x http://localhost:9999 https://target.com

# HTTP with auto-retry — use smart router on 9888
curl -x http://localhost:9888 http://target.com
```

---

## Recovery procedures

### Complete reset (nuclear option)

```bash
./1proxy2xvpn destroy --purge          # remove containers AND image
./1proxy2xvpn observability down       # if running
docker system prune -a               # clean any leftover docker state
rm -rf ~/.config/1proxy2xvpn         # clear credentials
sudo systemctl restart docker        # fresh daemon state
sudo systemctl restart haproxy

# Then rebuild:
./1proxy2xvpn build
./1proxy2xvpn up
sudo ./1proxy2xvpn haproxy
```

### Backup important state

Worth keeping safe:

```bash
# Generated HAProxy config
cp /etc/haproxy/haproxy.cfg ~/backup-haproxy.cfg

# Credentials
cp ~/.config/1proxy2xvpn/credentials ~/backup-credentials

# Blacklist
cp ~/.config/1proxy2xvpn/blacklist ~/backup-blacklist 2>/dev/null

# .env overrides
cp .env ~/backup-env
```

---

## Manual uninstall

The easiest way to remove everything is:

```bash
sudo ./1proxy2xvpn uninstall
```

If you prefer to do it by hand (or the command isn't available), remove each
artifact in order:

```bash
# 1. Stop and remove all proxy containers
docker rm -f $(docker ps -aq --filter "label=1proxy2xvpn.managed=true")

# 2. Stop and remove the observability stack (containers + volumes)
cd observability
docker compose -f docker-compose.observability.yml down -v
docker compose -f docker-compose.observability.full.yml down -v 2>/dev/null
cd ..
# Remove any leftover observability containers by name prefix
docker rm -f $(docker ps -aq --filter "name=1p2v-") 2>/dev/null

# 3. Remove the Docker image, network, and volumes
docker image rm 1proxy2xvpn:latest
docker network rm 1proxy2xvpn-observability 2>/dev/null
docker volume rm $(docker volume ls -q | grep -E "prometheus-data|grafana-data|loki-data|alertmanager-data") 2>/dev/null

# 4. Remove system files
sudo rm -f /etc/sysctl.d/99-1proxy2xvpn.conf
sudo rm -f /etc/modules-load.d/1proxy2xvpn.conf
sudo sed -i '/# 1proxy2xvpn — per-process file descriptor limits/,+2d' /etc/security/limits.conf

# 5. Remove the global symlink (if you created it)
sudo rm -f /usr/local/bin/1proxy2xvpn

# 6. Restore the original HAProxy config from the backup the tool made
sudo mv /etc/haproxy/haproxy.cfg.bak /etc/haproxy/haproxy.cfg 2>/dev/null \
  && sudo systemctl reload haproxy
# If you don't use HAProxy for anything else:
#   sudo systemctl stop haproxy && sudo systemctl disable haproxy

# 7. Remove systemd units (if installed)
sudo systemctl disable --now 1proxy2xvpn.service 1proxy2xvpn-router.service 2>/dev/null
sudo rm -f /etc/systemd/system/1proxy2xvpn*.service
sudo systemctl daemon-reload

# 8. Remove config and credentials
rm -rf ~/.config/1proxy2xvpn

# 9. (Optional) Remove the project directory and your .ovpn files
#    Only if you want a completely clean slate — back up your .ovpn first!
# rm -rf /path/to/1proxy2Xvpn
```

**Shared packages** (`docker.io`, `haproxy`) are left installed because other
software may depend on them. Remove them only if you're sure they're unused:

```bash
sudo apt-get remove docker.io haproxy
```

---

## Getting help

If none of the above solves your issue:

1. Search [existing GitHub issues](https://github.com/higoarm/1proxy2Xvpn/issues)
2. Open a new issue with:
   - Output of the **Quick diagnostic** section above
   - Logs of the failing container: `docker logs <name>`
   - The relevant section of your `.ovpn` file (without credentials)
   - What you've already tried

For **security-sensitive issues** (potential leaks, container escape), open a [Security Advisory](https://github.com/higoarm/1proxy2Xvpn/security/advisories/new) instead.
