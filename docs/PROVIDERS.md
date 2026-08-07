# VPN Provider Setup

How to obtain and configure `.ovpn` files for each major provider tested with `1proxy2Xvpn`.

> ⚠️ All examples assume you have a valid, paid subscription with the provider. Free VPNs are not recommended — they're typically slow, blocked by most targets, and may log your activity. For Bug Bounty work, choose providers that explicitly allow port forwarding and have a clear no-logging policy.

---

## Comparison Table

| Provider | Servers | Configs | Auth | Notes |
|----------|---------|---------|------|-------|
| **ExpressVPN** | ~3,000 | Manual download | Per-server credentials | Best quality, $$$, 164+ configs available |
| **Private Internet Access (PIA)** | ~35,000 | Bulk download | Username/password | Great value, supports port forwarding |
| **NordVPN** | ~5,500 | Bulk download | Service credentials | Stable, supports OpenVPN UDP/TCP |
| **Mullvad** | ~700 | Per-server export | Account number only | Privacy-focused, anonymous accounts |
| **Surfshark** | ~3,200 | Bulk download | Username/password | Unlimited devices |
| **ProtonVPN** | ~2,000 | Manual export | OpenVPN credentials (separate from account) | Strong privacy, free tier available |

---

## ExpressVPN

### Get the configs

1. Log in to <https://www.expressvpn.com>
2. Click **Set Up Other Devices** → **Manual Configuration** → **OpenVPN**
3. Download `.ovpn` files for each location you want. ExpressVPN provides one file per server.
4. Note your **OpenVPN username and password** shown on this page — they are **different** from your account credentials.

### File structure

ExpressVPN `.ovpn` files come fully self-contained — certificates and keys are embedded. They look like:

```
client
dev tun
proto udp
remote united-states-newyork.expressnetw.com 1195
...
<ca>...</ca>
<cert>...</cert>
<key>...</key>
```

### Credentials

Each `.ovpn` requires the same OpenVPN username/password. Place them in `secrets/<filename>.auth`:

```bash
# For my_expressvpn_us_newyork_udp.ovpn:
cat > secrets/my_expressvpn_us_newyork_udp.auth << EOF
your_openvpn_username
your_openvpn_password
EOF
chmod 0600 secrets/my_expressvpn_us_newyork_udp.auth
```

OR add the same auth file for all servers using a shared file (less secure):

```bash
# For all configs to share one auth file, add to each .ovpn:
echo "auth-user-pass /ovpn/auth.txt" >> ovpns/my_expressvpn_us_newyork_udp.ovpn
```

### Recommended servers for Bug Bounty

ExpressVPN's USA servers tend to be on residential ranges. Good choices:
- `my_expressvpn_usa_-_brooklyn_udp.ovpn`
- `my_expressvpn_usa_-_atlanta_udp.ovpn`
- `my_expressvpn_usa_-_chicago_udp.ovpn`
- `my_expressvpn_uk_-_docklands_udp.ovpn`

### Known issues

- **`my_expressvpn_evpn_-_usa_-_slc_test_udp.ovpn`** is an internal test config, not a real server — it fails to connect.
- Pakistan, Brooklyn, and a few other configs are sometimes unstable.

---

## Private Internet Access (PIA)

### Get the configs

1. Log in to <https://www.privateinternetaccess.com/pages/client-control-panel>
2. Download the **OpenVPN configuration files** (recommended preset: "strong" — AES-256, SHA-256)
3. Extract the zip — you get ~85 `.ovpn` files

### File structure

PIA `.ovpn` files reference external files for the certificates:

```
client
dev tun
proto udp
remote us-newyorkcity.privacy.network 1198
...
ca ca.rsa.4096.crt
crl-verify crl.rsa.4096.pem
```

You must keep `ca.rsa.4096.crt` and `crl.rsa.4096.pem` in the same directory as the `.ovpn` files.

### Credentials

PIA uses your account username (the one starting with `p` followed by digits, like `p1234567`) and password. Create `secrets/auth.txt`:

```bash
cat > secrets/auth.txt << EOF
p1234567
YourPIAPassword
EOF
chmod 0600 secrets/auth.txt
```

Then ensure each `.ovpn` contains `auth-user-pass /ovpn/auth.txt`.

### Recommended servers

PIA has good geographic spread. Useful for Bug Bounty:
- `us_california.ovpn`, `us_chicago.ovpn`, `us_florida.ovpn`
- `germany.ovpn`, `france.ovpn`, `netherlands.ovpn`
- `japan.ovpn`, `singapore.ovpn`

---

## NordVPN

### Get the configs

1. Visit <https://nordvpn.com/ovpn/>
2. Download the bulk archive OR select individual servers
3. Extract — you get pairs like `us1234.nordvpn.com.udp.ovpn` and `us1234.nordvpn.com.tcp.ovpn`

### Credentials

NordVPN requires **service credentials** (not your account login). Get them from:

<https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/>

Click "Show" next to **Service credentials**.

```bash
cat > secrets/auth.txt << EOF
your_service_username
your_service_password
EOF
chmod 0600 secrets/auth.txt
```

Configure each `.ovpn` to use it: `auth-user-pass /ovpn/auth.txt`.

### Tips

- UDP is faster, but some networks block it — keep some TCP configs as fallback.
- NordVPN files are named by server ID (e.g., `us12345`). Rename them to be human-readable for easier `./1proxy2xvpn status` output:
  ```bash
  mv us12345.nordvpn.com.udp.ovpn nord-us-12345.ovpn
  ```

---

## Mullvad

### Get the configs

1. Log in at <https://mullvad.net/account/openvpn-config>
2. Select platform (Linux), select servers, choose **UDP**
3. Download the generated zip

### Credentials

Mullvad uses **account number only** — no password. Each config has the account number baked in via:

```
auth-user-pass
```

And a separate file `mullvad_userpass.txt` containing:

```
1234567890123456
m
```

(Account number on the first line, the literal letter `m` on the second.)

### Tips

- Mullvad's anonymous account model is great for privacy but pairs awkwardly with Bug Bounty work that often requires legal accountability. Verify your VDP allows anonymous traffic origins before using.
- Mullvad has a smaller server fleet (~700) but consistently fast.

---

## ProtonVPN

### Get the configs

1. Subscribe to ProtonVPN Plus or Visionary
2. Log in at <https://account.protonvpn.com/downloads>
3. Click **OpenVPN configuration files**
4. Select **Linux**, **UDP**, and download per server or country

### Credentials

ProtonVPN has **separate OpenVPN credentials** from your account login:

<https://account.protonvpn.com/account#openvpn>

Use them in `secrets/auth.txt`.

### Tips

- ProtonVPN's secure-core servers route through Iceland/Switzerland/Sweden — adds latency, useful for geo-research.
- Free tier servers are usable but heavily rate-limited (~10 Mbps).

---

## Surfshark

### Get the configs

1. Sign in to <https://my.surfshark.com/vpn/manual-setup/main>
2. Choose **OpenVPN** → **UDP** (or TCP)
3. Download configs per location

### Credentials

Surfshark provides separate service credentials. Same pattern as NordVPN.

---

## Multi-provider setups

You can mix providers in a single deployment for IP diversity:

```
ovpns/
├── my_expressvpn_us_newyork_udp.ovpn   ← ExpressVPN
├── my_expressvpn_japan_tokyo_udp.ovpn  ← ExpressVPN
├── pia_us_chicago.ovpn                 ← PIA
├── pia_germany.ovpn                    ← PIA
├── nord-us-12345.ovpn                  ← NordVPN
└── mullvad-se-stk-001.ovpn             ← Mullvad

secrets/
├── my_expressvpn_us_newyork_udp.auth   ← ExpressVPN creds
├── my_expressvpn_japan_tokyo_udp.auth
├── pia_us_chicago.auth                 ← Same PIA creds for all PIA files
├── pia_germany.auth
├── nord-us-12345.auth                  ← Same Nord creds for all Nord files
└── mullvad-se-stk-001.auth
```

The CLI handles each container independently — it doesn't care which provider any `.ovpn` came from.

---

## Verifying VPN connectivity

After starting containers:

```bash
./1proxy2xvpn status
```

For each container showing `CONNECTING` after 60+ seconds:

```bash
docker logs <container-name>
```

Common errors:

| Error | Cause | Fix |
|-------|-------|-----|
| `AUTH_FAILED` | Bad credentials | Verify `secrets/<name>.auth` content |
| `TLS Error` | Cert mismatch | Re-download `.ovpn` (provider rotated certs) |
| `Connection refused` | Port blocked by host network | Try TCP variant of `.ovpn` |
| `Timeout waiting for tun0` | Server unreachable | Try a different server |
| `Cannot resolve host` | DNS issue at boot | Check `/etc/resolv.conf` on host |

---

## Provider-specific bandwidth and CPU

Rough measurements from real-world usage (single container, idle):

| Provider | Avg latency | CPU usage | RAM |
|----------|-------------|-----------|-----|
| ExpressVPN | 30-80 ms | 1-2% | 40 MB |
| PIA | 50-120 ms | 1-2% | 35 MB |
| NordVPN | 40-100 ms | 1-3% | 45 MB |
| Mullvad | 25-70 ms | 1-2% | 30 MB |
| ProtonVPN | 60-150 ms | 1-2% | 40 MB |

Under load (Nuclei full scan), CPU per container climbs to 5-15% as the OpenVPN process handles encryption.
