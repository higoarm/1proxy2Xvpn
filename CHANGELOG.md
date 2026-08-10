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
