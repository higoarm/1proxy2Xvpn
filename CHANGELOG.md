# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Planned
- Kubernetes manifests for cluster deployment
- Multi-host federation with HAProxy peers
- Browser extension for one-click proxy switching

---

## [2.15.0] — 2026-09-11

### Fixed (Release 8 — onboarding quick wins)
- **`ENABLE_SOCKS5` default was inconsistent across three files.** `03_up.sh`
  defaulted it to `true` while `entrypoint.sh` and `.env.example` used `false`,
  so without a `.env` SOCKS5 came up **enabled** — contradicting the documented
  "opt-in" design and wasting ~3 MB + a process per container. There is now a
  single source of truth in `lib_common.sh` (`false`); `03_up.sh` inherits it
  and the container entrypoint mirrors it. SOCKS5 is now genuinely opt-in, so
  the README's `ENABLE_SOCKS5=true` in the nmap/Hydra examples is correct and
  necessary (previously redundant). A clarifying note was added.
- **Removed the misleading `X-Region` example from the CLI help.** It showed
  `curl -H "X-Region: eu"` as if header-based regional routing worked, but the
  HAProxy frontends run in `mode tcp` (which can't read HTTP headers) and no
  `use_backend` rule selects a regional pool. Replaced with a working
  IP-rotation example. (Regional pools still exist as backends for manual ACL
  routing, as documented in ARCHITECTURE.)
- **Fixed CLI help flag grouping:** `--only-up` and `--public-stats` now appear
  under `haproxy` (where they belong), not visually under `proxychains`.
- **Removed dead `release-patch/minor/major` targets from the Makefile** that
  referenced a `scripts/release.sh` which doesn't exist.

---

## [2.14.1] — 2026-09-05

### Documentation
- **Full documentation audit against the current code.** Corrected everything
  that had drifted across the releases:
  - `docs/ARCHITECTURE.md`: health checks are now described as **semantic**
    (through-tunnel 204), not a "future TCP-only enhancement"; the smart router
    section now reflects **HTTPS/CONNECT support**, per-attempt fresh
    connections, and the protective throttle (previously it wrongly said
    "CONNECT not implemented"); the Kill Switch section documents **IPv6
    blocking**; the OpenVPN-death behavior is now **auto-restart**, not just
    "stays alive".
  - `docs/PROVIDERS.md` and `docs/TROUBLESHOOTING.md`: credentials now
    consistently use `ovpns/authvpn.txt` referenced via `auth-user-pass
    /ovpn/authvpn.txt` (the old `secrets/*.auth` scheme was removed in 2.4.4);
    fixed the directory-layout example and the `AUTH_FAILED` guidance.
  - `docs/INTEGRATIONS.md`: the smart router is now documented as handling
    HTTP **and HTTPS**, with a note on the protective throttle.
- Verified internal doc links, endpoint ports, and that new features
  (proxychains, Portainer, circuit breaker, IPv6) are represented.

---

## [2.14.0] — 2026-09-05

### Changed (Release 7 — robustness)
- **Docker health check is now truly local (no tunnel round-trip).** The check's
  comment claimed it avoided an external request, but the code actually proxied
  a request to cp.cloudflare.com through the VPN on every run — duplicating the
  HAProxy semantic check and wasting tunnel capacity at scale. It now verifies
  only: tun0 has an IP, the tinyproxy process is alive, and its port accepts a
  local TCP connection (plus dante when SOCKS5 is on). The through-tunnel check
  that decides rotation stays with HAProxy; Docker's check no longer adds egress.
- **smart_router now handles `Transfer-Encoding: chunked` request bodies**
  (common from Burp and chained tools). Chunked bodies were previously read as
  empty/truncated; they're now de-chunked and forwarded with a correct
  Content-Length. Bodyless requests (typical GET) are left untouched, preserving
  their fingerprint.
- **Defensive request limits in smart_router:** max header line size (16 KB, via
  the stream buffer limit), max header count (200), and a request-body cap
  (100 MB). Protects against malformed or abusive clients consuming memory.

### Not done (with rationale)
- **Per-container `nf_conntrack_max`** (report's scalability #1) was evaluated
  and deliberately NOT added. On modern kernels (5.13+, and backports to 5.4.120
  / 4.19.191 …) `net.netfilter.nf_conntrack_max` is **read-only in non-init
  network namespaces** — a security fix, since it used to be global. Passing
  `--sysctl net.netfilter.nf_conntrack_max` per container would fail with
  "permission denied" and break `up` on exactly the modern kernels this targets.
  The concern it addressed is already mitigated: `setup` sets
  `nf_conntrack_max=1048576` on the host, which each container's netns inherits.

---

## [2.13.0] — 2026-09-05

### Added (CircuitBreaker → protective throttle)
- **The circuit breaker is no longer decorative.** Its `is_burned()` signal was
  computed and discarded; it now drives a **protective throttle**: when the
  request failure rate crosses a threshold (a target blocking en masse), the
  smart_router slows the pace of NEW requests so it doesn't burn the entire VPN
  IP pool against a wall.
  - **Reversible & non-destructive by design:** it never removes a backend from
    rotation (in HAProxy `mode tcp` the router can't tell which VPN IP served a
    given request, so blacklisting a specific IP automatically isn't possible —
    slowing the pace is the safe, correct action). Releases automatically once
    the failure rate drops.
  - **Conservative & disableable** (legitimate fuzzing/brute-force produces many
    4xx by design): trips at 20 failures/60s by default. Tune via
    `SMART_ROUTER_CIRCUIT_THRESHOLD`, `SMART_ROUTER_CIRCUIT_WINDOW`,
    `SMART_ROUTER_CIRCUIT_THROTTLE`, or turn off with `SMART_ROUTER_CIRCUIT=off`.
  - **New metrics:** `smart_router_circuit_throttling` (0/1),
    `smart_router_burn_rate` (0..1), `smart_router_throttle_engaged_total`, so
    you can see in Grafana when the pool is under pressure and decide whether to
    intervene manually.

### Design note
- Automatic *blacklisting* (removing the burned IP) was evaluated and
  deliberately not implemented: the `mode tcp` architecture (required for
  HTTPS/CONNECT) means no layer knows which specific backend returned a block,
  so automatic removal would be a blind guess that could drop good IPs during a
  legitimate 4xx spike. The protective throttle achieves the goal (don't burn
  the pool) without that risk, and keeps the destructive decision (manual
  `blacklist add`) with the operator.

---

## [2.12.0] — 2026-09-05

### Fixed (Release 5 — audit findings, no-risk corrections)
- **`error()` undefined in the container entrypoint (regression from 2.8.0).**
  The OpenVPN restart-exhaustion path called `error` — which wasn't defined
  (only log/warn/die were) — under `set -Eeo pipefail`, so it aborted with 127
  and skipped `cleanup` (graceful shutdown of tinyproxy/dante/openvpn) and the
  clean `exit 1`. `error()` is now defined; the failure path runs correctly.
  This path had never been exercised because tests only covered the successful
  relaunch, not restart exhaustion.
- **Alert `HighProxyLatency` was inoperative.** It queried
  `haproxy_backend_http_request_duration_seconds_bucket`, which only exists for
  `mode http` backends — ours are `mode tcp`. Rewritten to use
  `haproxy_backend_response_time_average_seconds`, published in any mode.
- **Alert `ContainerRestartLoop` was almost always firing.** It used
  `rate(container_last_seen[5m]) > 0.5`, but that series grows ~1/s for any live
  container, so the rate is ~1 regardless of restarts. Rewritten to use
  `changes(container_start_time_seconds[10m]) > 2`, which counts real restarts.
- **SOCKS5 health-check interval was hardcoded to 5s**, ignoring
  `HAPROXY_CHECK_INTER` (which the HTTP backend honors) and reintroducing check
  overhead at scale. It now uses the same configurable interval.

### Security (CI/CD)
- **Pinned third-party CI actions by commit SHA** instead of mutable `@master`:
  `aquasecurity/trivy-action` → v0.36.0 SHA, `ludeeus/action-shellcheck` → 2.0.0
  SHA. Removes a supply-chain risk (a compromised action ran with
  `security-events: write`).
- **Trivy now fails the build on CRITICAL vulnerabilities** that have a fix
  available (`exit-code: 1`, `ignore-unfixed: true`). The SARIF uploads still run
  (they're `if: always`), so Code Scanning reports are unaffected.

### Credit
- These fixes come from an external source-code audit of the repository. Findings
  were verified against the code before applying.

---

## [2.11.1] — 2026-08-13

### Changed
- **README: observability is now clearly marked optional.** Added a prominent
  note in the Observability section explaining the tool runs fully without
  Prometheus/Grafana (which only power an optional metrics dashboard), that
  Prometheus is the data store and Grafana the viewer, and that
  `./1proxy2xvpn status` covers quick health checks with no stack needed.
  Tagline, About highlights, and Features subsection updated to say "optional".
  CLI Reference observability line updated to include `portainer`.

---

## [2.11.0] — 2026-08-13

### Added
- **Progress bar for `haproxy --only-up`.** The per-container VPN connectivity
  check (~5s each) now shows a filling progress bar, so a large pool no longer
  looks frozen. Skipped containers still print on their own line.
- **Portainer password is now set automatically.** The 5-minute initial-setup
  security timeout was locking users out (and persisted in the volume across
  reinstalls). The CLI now generates an admin password, passes it via
  `--admin-password-file`, and prints it — so Portainer is ready immediately, no
  race against the timer.
- **`observability portainer-reset`** wipes Portainer's data volume to recover
  from a prior timeout / forgotten password, then you can start clean.

### Changed
- **Cleaner, more professional result layout.** New `kv`/`kv_sub` helpers render
  aligned "label ···· value" blocks (Endpoints, Execution plan) that are easier
  to scan.

---

## [2.10.1] — 2026-08-13

### Fixed
- **`up` aborted at the first container (stuck at ~2%).** The new progress bar's
  final line was `[ current -ge total ] && printf` — when current < total the
  test returns exit 1, so under the script's `set -e` the function returned
  non-zero and killed the whole `up`. The function now uses an explicit `if`
  and `return 0`, so `up` runs to completion again. (Regression from 2.10.0.)

---

## [2.10.0] — 2026-08-12

### Added (Release 4 — polish)
- **Startup progress bar.** `up` now shows a filling progress bar (0→100%) as
  containers start, instead of one line per container — much cleaner with dozens
  of VPNs. Failures still print on their own line above the bar.
- **Portainer (optional).** `./1proxy2xvpn observability up portainer` starts
  Portainer CE for visual container management (inspect, start/stop, logs),
  complementing Grafana/cAdvisor metrics. Bound to https://localhost:9444
  (localhost-only, since Docker-socket access is powerful). Torn down by
  `observability down` and by `uninstall`.

### Not done (with rationale)
- **X-Region header** was in the improvement list, but no such header exists
  anywhere in the current code or docs (it was removed in an earlier cleanup),
  so there is no inconsistency to fix. Implementing it is also not viable: the
  backends run in `mode tcp` (required for the proxy/CONNECT to work), where
  HAProxy cannot inject HTTP headers — and injecting headers into the user's
  outbound requests would alter their fingerprint, which is undesirable for Bug
  Bounty. The exit IP (what the header would convey) is already visible to the
  target and via `./1proxy2xvpn status`.

---

## [2.9.0] — 2026-08-12

### Changed (Release 3 — the big gap: HTTPS support)
- **smart_router now supports HTTPS (CONNECT tunneling).** Previously it returned
  501 for CONNECT, making it useless for HTTPS — i.e. useless for ~all Bug Bounty
  traffic (Burp, sqlmap, ffuf, nuclei, httpx against HTTPS targets). It was
  rewritten as a raw-asyncio forward proxy that tunnels HTTPS: each CONNECT opens
  a NEW upstream connection to HAProxy, so every tunnel exits through a different
  VPN IP.
- **Retry now actually rotates the IP.** The old aiohttp client reused pooled
  keep-alive connections, so a retry after a 403/429 went out over the SAME
  connection (same IP), defeating the purpose. Each HTTP attempt now uses a fresh
  upstream connection, so HAProxy round-robins to a different VPN IP on every
  retry.
- smart_router no longer depends on aiohttp — it uses only the Python standard
  library. `prometheus_client` is now optional (enables `/metrics`; the proxy
  runs fine without it). `requirements.txt` updated accordingly.
- README gained a "Smart router" section documenting HTTP+HTTPS usage.

### Validated
- HTTP retry (upstream 403,403,200 → served on attempt 3, fresh connection each
  attempt), HTTPS CONNECT tunneling (real TLS round-trip to api.github.com),
  `/metrics` and `/health` endpoints — all tested end-to-end.

---

## [2.8.0] — 2026-08-12

### Changed (Release 2 — reliability)
- **OpenVPN now auto-restarts.** When the tunnel process dies, the in-container
  monitor relaunches OpenVPN (up to OVPN_MAX_RESTARTS, default 10) instead of
  leaving the container alive-but-VPN-less. The Kill Switch stays active
  throughout, so there is never a leak during recovery; if restarts are
  exhausted, the container exits so Docker's restart policy recreates it cleanly.
- **HAProxy health checks are now semantic.** Instead of a plain TCP check (which
  only confirmed tinyproxy's port was open), HAProxy sends a real proxied request
  through each container and expects a 204 — verifying the VPN tunnel actually
  works. A container whose tunnel is dead now leaves rotation instead of
  receiving traffic that fails. Applied to the main and regional HTTP backends.
  Check interval is tunable via HAPROXY_CHECK_INTER (default 10s) to control
  overhead at scale. SOCKS5 backends keep the TCP check (httpchk is HTTP-only).

### Note
- The `haproxy` command already validates the generated config with `haproxy -c`
  before applying, so a bad check config can never take down a running HAProxy.

---

## [2.7.0] — 2026-08-12

### Security
- **IPv6 Kill Switch** (Release 1). Previously the Kill Switch only covered
  IPv4, so on a host/target with IPv6 connectivity, traffic could leak outside
  the (IPv4-only) VPN tunnel and expose the real address. IPv6 is now fully
  blocked via `ip6tables` deny-by-default — both at container boot (baseline,
  closing the boot-window) and in the full Kill Switch. Falls back to disabling
  IPv6 via sysctl if `ip6tables` is unavailable.

### Changed
- **Removed the `ConnectPort` whitelist** in `tinyproxy.conf` (Release 1). It
  previously allowed CONNECT only on 443/563/8443/8080/9443, which silently
  broke EASM/Bug Bounty scans against targets on non-standard ports (8444,
  10443, 2096, 61000, etc.). With no `ConnectPort` directive, tinyproxy allows
  CONNECT to any port — correct for this isolated, Kill-Switch-protected proxy.
  Instructions to re-restrict are included as comments.

---

## [2.6.0] — 2026-08-11

### Added
- **`proxychains` command** — generates a ready-to-use `proxychains.conf` from
  the running containers, mirroring what `haproxy` does for HAProxy. It lists
  every container's SOCKS5 proxy and uses `random_chain` + `chain_len=1`, so
  proxychains picks one random proxy per connection — the same per-connection IP
  rotation as the HAProxy endpoint, usable with tools that only proxy through
  proxychains (nmap, hydra, etc.).
  - `./1proxy2xvpn proxychains` writes `./proxychains.conf` (use with
    `proxychains4 -f proxychains.conf <tool>`).
  - `sudo ./1proxy2xvpn proxychains --install` also installs it to
    `/etc/proxychains4.conf` (backing up any existing file) so you can drop the
    `-f` flag.
  - Warns clearly if SOCKS5 isn't enabled on the containers or if proxychains
    isn't installed.
- README nmap and Hydra examples now use the generated `proxychains.conf`.

---

## [2.5.1] — 2026-08-11

### Fixed
- **Corrected the nmap example.** nmap's `--proxies` flag does not support
  SOCKS5 (only HTTP and SOCKS4), so `--proxies socks5://...` fails with "Invalid
  protocol in proxy specification". The docs and test roadmap now route nmap TCP
  connect scans through **proxychains** (which speaks SOCKS5), and clarify that
  SYN/UDP/OS-detection can't traverse a proxy at all.

---

## [2.5.0] — 2026-08-11

### Changed
- **About section rewritten** to make the provider use case explicit: the tool
  turns `.ovpn` files from commercial VPN providers (ExpressVPN, NordVPN,
  Surfshark, PIA, Mullvad, or any OpenVPN-based provider) into a rotating proxy
  pool. Added a bulleted provider list.

---

## [2.4.9] — 2026-08-10

### Added
- Two more Demo slots for screenshots: **HAProxy stats** and **Grafana
  dashboard**, each with a caption. Added a `docs/media/` folder for committing
  screenshots via git (or drop them in the GitHub web editor).

---

## [2.4.8] — 2026-08-10

### Changed
- Demo section now uses GitHub-native embedded video (upload the .mp4 directly)
  instead of YouTube thumbnail links, so the videos play inside the README
  without leaving the page. Captions kept; placeholders mark where to drop each
  file in the GitHub web editor.

---

## [2.4.7] — 2026-08-09

### Added
- **Demo section** in the README with two YouTube walkthroughs (installation and
  live IP rotation), shown as clickable thumbnails with captions. Added a Demo
  entry to the Table of Contents.

---

## [2.4.6] — 2026-08-08

### Changed
- **Quick Start simplified.** Removed the optional `install-cli` step from the
  README (it was causing confusion) and added `newgrp docker` right after
  `setup`, so a fresh Docker install picks up the new group membership and the
  following commands don't fail with a `docker.sock` permission error. The
  `install-cli` command still exists for those who want a global command.

---

## [2.4.5] — 2026-08-08

### Changed
- Credentials file example renamed from `conecta.txt` to `authvpn.txt` across
  the docs and launcher comments. Any filename still works — this only changes
  the suggested name. Reference it as `auth-user-pass /ovpn/authvpn.txt`.

---

## [2.4.4] — 2026-08-08

### Changed
- **Credentials now live inside `ovpns/`**, next to the `.ovpn` files. That
  directory is already mounted at `/ovpn` in every container, so no extra mount
  is needed. Reference them in your `.ovpn` as `auth-user-pass /ovpn/conecta.txt`
  (or a relative `conecta.txt`). The launcher validates the file exists in
  `ovpns/` and warns early if it's missing.
- The tool no longer injects any `auth-user-pass` directive — the `.ovpn` is the
  single source of truth for credentials.

### Security
- `.gitignore` now excludes **all** of `ovpns/` (except `.gitkeep`), so
  credential files of any name (e.g. `conecta.txt`) can never be committed.

---

## [2.4.3] — 2026-08-08

### Fixed
- **Containers failed to connect for providers requiring username/password**
  (ExpressVPN, NordVPN, etc.). The launcher mounted the credentials at
  `/ovpn/auth.txt` but the entrypoint never passed `--auth-user-pass` to
  OpenVPN, so configs with an `auth-user-pass` directive tried to prompt on a
  non-interactive console and the tunnel never came up (containers restarted in
  a loop). The entrypoint now injects `--auth-user-pass /ovpn/auth.txt` when the
  file is present, and prints a clear, actionable warning when a config needs
  credentials but none were provided. Providers that embed credentials inline
  (e.g. PIA) are unaffected.

---

## [2.4.2] — 2026-08-07

### Fixed
- **Grafana failed to start** with "Only one datasource per organization can be
  marked as default". Cause: a leftover `datasources.full.yml` sat inside the
  provisioning directory Grafana reads, so it loaded two Prometheus datasources
  both marked default. The Loki datasource (full stack only) now lives outside
  the shared provisioning dir (`grafana/provisioning-loki/loki.yml`) and is
  mounted individually by the full compose. The lite stack provisions only
  Prometheus; no duplicate default is possible.

---

## [2.4.1] — 2026-08-07

### Added
- **Bug Bounty Use Cases** section in the README: a table mapping the tool to
  common authorized-testing scenarios (IP-ban bypass, rate-limit bypass, recon
  pipeline rotation, Nuclei/ffuf/sqlmap/nmap/Hydra with rotating IPs, etc.).
- Integration examples for **dirsearch, gobuster, and Hydra** (via proxychains
  over SOCKS5).

---

## [2.4.0] — 2026-08-07

### Added
- `install-cli` command: installs the global `1proxy2xvpn` command and diagnoses
  the "sudo: command not found" issue (sudo `secure_path` not including
  `/usr/local/bin`), with two clear fixes. `--remove` uninstalls it.
- `logs` now accepts `-f`/`--follow`; for a specific container it defaults to a
  one-shot dump of the last 100 lines (so `logs <name> | tail -20` works).
- Grafana healthcheck; `observability up` now waits for Grafana to be ready and
  prints the URL when it is.

### Changed
- **README fully restructured** (About, Table of Contents, section separators)
  for a cleaner landing page. Requirements table simplified to a single tier.
- Region grouping is now clearly documented as filename-based (not GeoIP), with
  the rationale and the GeoIP alternative, in `docs/ARCHITECTURE.md`.
- Startup banner reworded (removed the "Tor-style" phrasing).

### Fixed
- **Credentials now belong to the invoking user**, not root: when run under
  sudo, config and credentials are written to the real user's
  `~/.config/1proxy2xvpn` and chowned accordingly, so you can read them without
  sudo.
- `setup` no longer prints a spurious "docker-compose-plugin unavailable"
  warning when a working `docker compose` is already present.

### Removed
- "Production deployment" and "Security disclosure" sections from the README.

---

## [2.3.3] — 2026-08-06

### Fixed
- **Gitleaks false positive** on the HAProxy stats example in
  `docs/TROUBLESHOOTING.md`: the `curl -u "admin:..."` command read the password
  via inline command substitution, which the scanner flagged as a hardcoded
  secret. Rewritten to read the password into a variable first, and added a
  `.gitleaks.toml` that allowlists documentation placeholders (e.g.
  `your_openvpn_password`) while keeping real-secret detection active on every
  file — no whole-path exclusions.
- **CI shellcheck failures**: fixed SC2188 (redirect without command in
  `08_blacklist.sh`), SC2034 (unused API variables in `lib_common.sh`), SC1090
  (dynamic `.env` source), and an unused loop variable in `entrypoint.sh`.
- **CI ruff failures**: removed unused imports (`json`, `defaultdict`,
  `start_http_server`) from `smart_router.py`, sorted imports, and modernized a
  type hint. Added `ruff.toml` to pin the lint rule set so results don't drift
  with ruff releases.
- **CI hadolint failure**: fixed SC2015 (`A && B || C` ambiguity) in the
  Dockerfile's `/dev/net/tun` setup by grouping best-effort commands.

### Added
- `.gitleaks.toml` and `ruff.toml` for deterministic, reproducible security and
  lint scanning.

---

## [2.3.2] — 2026-08-06

### Added
- **`uninstall` command** for complete removal: `sudo ./1proxy2xvpn uninstall`
  removes all containers, the observability stack, the Docker image and volumes,
  system files (sysctl, modules-load, `limits.conf` block, global symlink),
  systemd units, and `~/.config/1proxy2xvpn` — and restores the original
  `/etc/haproxy/haproxy.cfg` from backup. Flags: `--yes` (non-interactive),
  `--purge` (also delete config and project directory). Preserves `.ovpn` files
  by default.
- Manual uninstall walkthrough in `docs/TROUBLESHOOTING.md` and an Uninstall
  section in the README.

### Changed
- The post-`haproxy` test hint now shows the 10-request rotation loop instead of
  a single request, so the output demonstrates IP rotation.

---

## [2.3.1] — 2026-08-06

### Fixed
- **Critical: `setup` could report success without installing HAProxy.** Three
  compounding bugs are fixed:
  - Dependencies were installed in a single `apt-get` call, so one failing
    package (e.g. a `docker.io` conflict) aborted the whole install — HAProxy
    included. Packages are now installed **one by one**, so a single failure no
    longer blocks the rest.
  - Install errors were swallowed by `|| true`, printing "Dependencies
    installed" even on failure. Removed.
  - The final HAProxy/Docker check used `fail` (non-aborting), so setup printed
    "Setup complete" even when a critical tool was missing. Setup now **verifies
    every critical dependency (haproxy, docker, curl, openssl, ip) and aborts
    with an actionable error** if any is absent.
- `/dev/net/tun` creation failure now aborts setup instead of warning silently.
- Docker daemon not running now aborts with a clear fix instead of a soft
  warning.
- All user-facing command hints across scripts and docs now use `./1proxy2xvpn`
  (with `sudo` where required), matching how the tool runs without a global
  install.
- CLI now invokes subcommands via `bash`, so a missing execute bit on
  `scripts/*.sh` (common after unzipping) no longer breaks any command.

### Added
- Troubleshooting entry for `HAProxy not installed` with concrete recovery steps.

---

## [2.3.0] — 2026-08-06

### Added
- **sqlmap and nmap** integration examples in the README (HTTP proxy for sqlmap,
  SOCKS5 tunneling for nmap TCP connect scans).
- Direct link from the Requirements section to the recommended host
  configurations in `docs/PERFORMANCE.md`.

### Changed
- **All CLI examples in the README now use `./1proxy2xvpn`** (with a note on
  the optional global install), matching how the tool runs from the project
  directory without a global symlink.
- Quick Start test step now runs a 10-request loop that demonstrates IP rotation.

### Removed
- **`SECURITY.md`** removed; the security disclosure policy is now inline in the
  README (GitHub security advisory link). References updated in `CONTRIBUTING.md`.

---

## [2.2.0] — 2026-05-31

### Changed
- **HAProxy load balancing switched from `random` to `roundrobin`** across all
  backends (HTTP pool, SOCKS5 pool, regional pools). Round-robin cycles through
  every server in order before repeating any, guaranteeing maximum IP diversity.
  The previous `random` algorithm could select the same exit IP two or three
  times in a row by chance; round-robin eliminates that, using all N IPs once
  before reusing the first.

### Notes
- Rotation is per new connection. Clients that reuse a keep-alive connection for
  many requests keep the same IP for that connection's lifetime — disable
  keep-alive client-side for strict per-request rotation.

---

## [2.1.0] — 2026-05-31

### Changed
- **Observability stack slimmed from 7 services to 3** (Prometheus + Grafana +
  cAdvisor). Removed Loki, Promtail, Alertmanager, and node-exporter, which ran
  without practical use at scale. Full stack preserved as
  `docker-compose.observability.full.yml` (run via `observability up full`).
- **cAdvisor tuned for scale**: `housekeeping_interval` raised from 1s to 30s,
  `docker_only` mode, expensive metric families disabled. ~20-30× less CPU with
  285 containers.
- **SOCKS5 (dante) is now opt-in** (`ENABLE_SOCKS5=false` by default). Saves a
  process and ~3MB RAM per container when not needed.
- **In-container monitor interval** raised from 5s to 30s (`MONITOR_INTERVAL`).
- **Healthcheck simplified**: removed the per-check external IP round-trip (leak
  test now runs once at boot); interval raised 30s → 60s.
- Prometheus retention trimmed 30d → 7d; scrape interval 15s → 30s.
- Removed unused packages (`iputils-ping`, `jq`) from the container image.

---

## [2.0.0] — 2026-05-17

Major rewrite focused on production readiness, security hardening, and observability.

### Added
- **Unified CLI** (`1proxy2xvpn`) replacing standalone scripts
- **SOCKS5 support** via dante-server alongside HTTP via tinyproxy (per container)
- **Regional pools** in HAProxy auto-detected from `.ovpn` filename
- **Blacklist API** to disable burned IPs without restart (`1proxy2xvpn blacklist`)
- **Smart router middleware** with auto-retry on 403/429/451 (`middleware/smart_router.py`)
- **Full observability stack** — Prometheus, Grafana, Loki, Promtail, Alertmanager, cAdvisor, node-exporter
- **Pre-built Grafana dashboard** with VPN pool health, latency, throughput, per-container metrics
- **Production alerts** — HAProxy down, backend failures, memory pressure, file descriptor exhaustion
- **systemd integration** with hardened service units
- **CI/CD workflows** — shellcheck, hadolint, yamllint, ruff, Trivy CVE scan, Gitleaks
- **Multi-arch image builds** for `amd64` and `arm64`
- **Pre-commit hooks** for local development
- **Comprehensive docs** — Architecture, Providers, Performance, Integrations, Troubleshooting

### Changed
- **BREAKING**: Replaced `--privileged` with explicit capabilities (`NET_ADMIN`, `NET_RAW`)
- **BREAKING**: Stats panel password now randomly generated, stored in `~/.config/1proxy2xvpn/credentials`
- **BREAKING**: Stats panel binds to `127.0.0.1` by default (use `--public-stats` to override)
- **BREAKING**: Container restart policy changed from `unless-stopped` to `on-failure:10`
- Boot order now applies baseline `iptables` DROP **before** any service starts
- DNS leak prevention: pre-resolves VPN hostname and pins via `/etc/hosts`
- Injects `redirect-gateway def1` and `block-outside-dns` into `.ovpn` if missing
- Default error pages on tinyproxy now generic (no fingerprint)
- Containers labeled for Promtail auto-discovery
- HAProxy now binds Prometheus metrics endpoint on `127.0.0.1:8404`

### Security
- Closed boot-window leak via `iptables-baseline.rules` applied at container start
- Removed all hardcoded credentials (no more `haproxy:ham123`)
- Per-container auth file isolation (no shared `auth.txt`)
- Anti-fingerprint defaults in `tinyproxy.conf`
- Semantic health check verifies VPN actually works (not just TCP port)
- `--security-opt no-new-privileges` on all containers

### Fixed
- Cleanup bug where orphaned containers survived image rebuild (now 2-layer cleanup)
- HAProxy stats showing wrong status due to TCP-only checks
- `tinyproxy-detect` Nuclei false positives (anti-fingerprint config)
- DNS leak during VPN reconnection (hostname pinned to IP)

---

## [1.0.0] — 2025-09-XX

Initial public release.

### Added
- Containerized OpenVPN + tinyproxy with Kill Switch via iptables
- Bash scripts for build, start, generate HAProxy config, check status
- README with installation and usage
- Single-container Docker Compose example

[Unreleased]: https://github.com/higoarm/1proxy2Xvpn/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/higoarm/1proxy2Xvpn/releases/tag/v2.0.0
[1.0.0]: https://github.com/higoarm/1proxy2Xvpn/releases/tag/v1.0.0
