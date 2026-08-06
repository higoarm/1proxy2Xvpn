# Integrating with Security Tools

Tool-by-tool guide for using `1proxy2Xvpn` in your testing workflow.

---

## Endpoint cheat sheet

| Protocol | Endpoint | Use case |
|----------|----------|----------|
| HTTP/HTTPS | `http://localhost:9999` | Web scanners, browsers, curl |
| SOCKS5 | `socks5://localhost:9998` | sqlmap, hydra, custom scripts |
| HTTP with auto-retry | `http://localhost:9888` | When you need IP rotation on 403/429 |
| Stats panel | `http://localhost:9997` | Monitor pool health |
| Prometheus | `http://localhost:8404/metrics` | Custom metrics export |

---

## Nuclei

### The right way

Run in **two passes** — proxy for HTTP, direct for DNS/SSL:

```bash
# Pass 1: HTTP templates via proxy (IP rotation)
nuclei -u target.com \
    -proxy http://localhost:9999 \
    -type http \
    -exclude-tags proxy,fingerprint \
    -exclude-id tinyproxy-detect,squid-detect,generic-proxy-detect \
    -c 25 -rate-limit 150 \
    -o nuclei-http.txt

# Pass 2: DNS, SSL, WHOIS — directly (no proxy)
nuclei -u target.com \
    -type dns,ssl,whois \
    -o nuclei-other.txt
```

### Why two passes

Templates of type `dns`, `ssl`, `tcp`, `whois` don't work over an HTTP proxy. Forcing them through one produces:

- False positives from `tinyproxy-detect` matching the proxy itself
- Empty results from queries that silently fail
- DNS leaks via the proxy's error path

See `README.md` → "Using with Nuclei" for the full explanation.

### Auto-retry with smart router

When testing aggressively rate-limited targets:

```bash
nuclei -u target.com -proxy http://localhost:9888 \
    -type http \
    -exclude-tags proxy,fingerprint
```

The smart router transparently retries 403/429 responses with a different VPN backend.

---

## Burp Suite

### Upstream proxy configuration

**User options → Connections → Upstream Proxy Servers**:

| Field | Value |
|-------|-------|
| Destination host | `*` |
| Proxy host | `127.0.0.1` |
| Proxy port | `9999` |
| Proxy type | `HTTP` |
| Auth | None |

### Disable connection reuse

Burp keeps connections alive aggressively, which defeats IP rotation. To force a new IP per request:

**User options → Misc → HTTP** → uncheck **Use HTTP/1.1 keep-alive**

### Active Scan++ tuning

When scanning with proxy backend, reduce concurrency:

**Dashboard → New scan → Scope → Scan configuration**:

- Concurrent requests: **10** (default 20)
- Throttle: **100ms between requests**

This avoids overwhelming HAProxy with bursts.

### SOCKS5 alternative

Burp also supports SOCKS5:

**User options → Connections → SOCKS Proxy**:

- Type: `SOCKS5`
- Host: `127.0.0.1`
- Port: `9998`
- DNS through SOCKS: enabled

---

## Caido

Caido uses similar configuration to Burp.

**Settings → Network → HTTP proxy**:

```
Address: 127.0.0.1
Port:    9999
```

For traffic that requires SOCKS5 (e.g., proxying non-HTTP protocols):

```
SOCKS proxy: 127.0.0.1:9998
```

Caido's workflow plugins can integrate with the smart router for automated 403 retry:

```
Upstream: http://localhost:9888
```

---

## ffuf

### Basic usage

```bash
ffuf -u "https://target.com/FUZZ" \
     -w /usr/share/wordlists/dirb/common.txt \
     -x http://localhost:9999 \
     -t 50
```

### Avoiding rate limits

Combine with auto-retry:

```bash
ffuf -u "https://target.com/FUZZ" \
     -w wordlist.txt \
     -x http://localhost:9888 \  # smart router
     -t 30 \
     -mc all -fc 403,429         # show all, filter rate-limited
```

### Header rotation

Combine IP rotation with header diversity:

```bash
ffuf -u "https://target.com/FUZZ" \
     -w wordlist.txt \
     -x http://localhost:9999 \
     -H "User-Agent: ..." \
     -H "X-Forwarded-For: AUTORATE"  # use AUTORATE feature for header fuzzing
```

---

## sqlmap

Requires **SOCKS5** for non-HTTP protocols:

```bash
sqlmap -u "https://target.com/page?id=1" \
       --proxy="socks5://127.0.0.1:9998" \
       --random-agent \
       --delay=1 \
       --timeout=30 \
       --retries=2
```

For HTTP-only injections, HTTP proxy works:

```bash
sqlmap -u "https://target.com/page?id=1" \
       --proxy="http://127.0.0.1:9999" \
       --random-agent
```

---

## hydra

```bash
hydra -L users.txt -P passwords.txt \
      ssh://target.com \
      -t 4 \
      -W 5 \
      -e nsr \
      -s 22 \
      -o results.txt \
      -V \
      -m "PROXY=http://127.0.0.1:9999"
```

For HTTP form bruteforcing:

```bash
hydra -L users.txt -P passwords.txt \
      target.com http-post-form "/login.php:user=^USER^&pass=^PASS^:F=invalid" \
      -t 8 \
      -m "PROXY=http://127.0.0.1:9999"
```

> ⚠️ Only use against authorized targets within Bug Bounty scope.

---

## sublist3r / subfinder / amass

These tools are mostly DNS-based and **shouldn't go through the HTTP proxy**. Run them directly:

```bash
subfinder -d target.com -all -o subs.txt
amass enum -d target.com -o amass.txt
```

For HTTP-based subdomain validation (`httpx`):

```bash
cat subs.txt | httpx -proxy http://127.0.0.1:9999 -title -tech-detect -status-code
```

---

## httpx

```bash
cat hosts.txt | httpx \
    -proxy http://localhost:9999 \
    -threads 50 \
    -timeout 10 \
    -follow-redirects \
    -title -tech-detect -status-code \
    -o results.txt
```

---

## gau / waybackurls

These query the Wayback Machine and similar archives — they need their own rate limit handling but can route through the proxy:

```bash
echo target.com | gau --proxy http://localhost:9999 --threads 5
```

---

## katana

```bash
katana -u target.com \
       -proxy http://localhost:9999 \
       -d 3 \
       -c 25 \
       -rl 100 \
       -o crawl.txt
```

---

## Browsers (manual testing)

### Firefox

1. **Settings → General → Network Settings → Manual proxy configuration**
2. HTTP Proxy: `127.0.0.1`, Port: `9999`
3. Check **Also use this proxy for HTTPS**
4. **No proxy for**: `localhost, 127.0.0.1` (so dev tools work)

Bonus: install **FoxyProxy** extension to toggle the proxy quickly.

### Chrome/Chromium

```bash
google-chrome --proxy-server="http://localhost:9999" \
              --user-data-dir=/tmp/chrome-proxy
```

For SOCKS5:

```bash
google-chrome --proxy-server="socks5://localhost:9998"
```

---

## Custom scripts

### Python (`requests`)

```python
import requests

proxies = {
    "http":  "http://localhost:9999",
    "https": "http://localhost:9999",
}

r = requests.get("https://api.ipify.org", proxies=proxies, timeout=10)
print(r.text)
```

To use SOCKS5:

```python
proxies = {
    "http":  "socks5h://localhost:9998",
    "https": "socks5h://localhost:9998",
}
```

Note: `socks5h://` ensures DNS resolution happens through the SOCKS server (not locally).

### Python (`aiohttp`) — high concurrency

```python
import asyncio
import aiohttp

async def fetch(session, url):
    async with session.get(url, proxy="http://localhost:9999") as r:
        return await r.text()

async def main():
    async with aiohttp.ClientSession() as session:
        tasks = [fetch(session, "https://api.ipify.org") for _ in range(100)]
        results = await asyncio.gather(*tasks)
        # Each request likely got a different VPN IP
        print(set(results))

asyncio.run(main())
```

### Go

```go
proxyURL, _ := url.Parse("http://localhost:9999")
client := &http.Client{
    Transport: &http.Transport{Proxy: http.ProxyURL(proxyURL)},
    Timeout:   10 * time.Second,
}
resp, _ := client.Get("https://api.ipify.org")
```

### curl one-liners

```bash
# Verify IP rotation
for i in {1..10}; do curl -s -x http://localhost:9999 https://api.ipify.org; echo; done

# Speed test for a specific container
curl -x http://localhost:3100 -w "@curl-format.txt" -o /dev/null https://httpbin.org/get

# Where curl-format.txt:
#    time_namelookup:    %{time_namelookup}s\n
#    time_connect:       %{time_connect}s\n
#    time_total:         %{time_total}s\n
```

---

## Recon automation pipelines

### Pattern: parallel scan with rotation

```bash
cat targets.txt | parallel -j 50 \
    "curl -s -x http://localhost:9999 -o /dev/null -w '%{http_code} {}\n' {}"
```

### Pattern: pipeline with explicit per-stage proxy use

```bash
subfinder -d target.com -silent \
  | httpx -proxy http://localhost:9999 -silent \
  | nuclei -proxy http://localhost:9999 -severity critical,high -type http
```

---

## Targeting regional pools

The HAProxy config auto-detects regional pools from `.ovpn` filenames. To explicitly target a region:

1. Edit `haproxy.cfg` to add an ACL-based routing rule:

```haproxy
frontend http_proxy_entrypoint
    bind *:9999
    acl is_eu_path path_beg /eu/
    use_backend http_vpn_pool_eu if is_eu_path
    default_backend http_vpn_pool
```

2. Reload HAProxy: `sudo systemctl reload haproxy`

3. Use the path prefix:

```bash
# Will route through European VPNs only
curl -x http://localhost:9999 https://target.com/eu/some-path
```

This is one approach — another is dedicated ports per region. Future versions will expose this as a CLI flag.

---

## Common integration gotchas

| Issue | Cause | Fix |
|-------|-------|-----|
| Tools time out frequently | Default timeouts too low for VPN | Set proxy/connection timeout ≥ 30s |
| Same IP appearing repeatedly | Tool reusing TCP connection | Disable keep-alive in tool config |
| `tinyproxy-detect` false positives | Routing DNS-type queries through HTTP proxy | Run DNS tools without proxy (`-type http` only for Nuclei) |
| SSL errors when using HTTPS through proxy | Tool not handling CONNECT method properly | Try SOCKS5 (`:9998`) instead |
| Burst of 5xx errors | HAProxy `option redispatch` kicking in for slow VPNs | Increase backend timeouts in `haproxy.cfg` |
| Some tools refusing SOCKS5 | Tool doesn't support SOCKS5 protocol | Use HTTP proxy (`:9999`) — most tools support both |
