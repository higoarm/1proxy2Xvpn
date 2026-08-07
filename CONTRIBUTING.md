# Contributing to 1proxy2Xvpn

Thank you for your interest in contributing. This project serves the cybersecurity community, so contributions must maintain a high bar for security, reliability, and ethical use.

---

## Code of Conduct

- Be respectful and constructive in discussions.
- Assume good faith from other contributors.
- Personal attacks, harassment, or discriminatory language will not be tolerated.
- This project explicitly rejects contributions intended to enable unauthorized access to systems.

---

## How to contribute

### Reporting bugs

1. Check existing [issues](https://github.com/higoarm/1proxy2Xvpn/issues) first.
2. Open a new issue with:
   - OS and kernel version (`uname -a`)
   - Docker version (`docker --version`)
   - HAProxy version (`haproxy -v`)
   - Output of `1proxy2xvpn status --json`
   - Logs from the affected container: `docker logs <name>`
   - Steps to reproduce

### Requesting features

Open an issue tagged `enhancement`. Describe:
- The problem you're trying to solve
- Why existing functionality is insufficient
- Proposed approach (optional)

### Submitting pull requests

1. Fork the repository and create a feature branch from `main`.
2. Make your changes following the guidelines below.
3. Run all checks locally before pushing:
   ```bash
   pre-commit run --all-files
   ```
4. Write a clear PR description explaining the **why**, not just the **what**.
5. Reference any related issues.

---

## Development guidelines

### Code style

- **Shell scripts**: pass `shellcheck -S warning`. Use `set -e` and explicit error handling. Quote variables.
- **Dockerfile**: pass `hadolint`. Pin versions when reasonable. Use multi-stage builds where it helps.
- **Python**: pass `ruff check`. Type-hint public functions. Use `async/await` consistently in the middleware.
- **YAML**: pass `yamllint`. 2-space indent. No trailing spaces.

### Commits

Follow Conventional Commits format:

```
feat: add SOCKS5 sticky session support
fix: resolve DNS leak during reconnect
docs: expand performance tuning guide
chore(ci): bump Trivy to 0.50
```

Prefixes: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `perf`, `security`.

### Testing changes

For changes touching the container:
```bash
1proxy2xvpn build --no-cache
1proxy2xvpn down
1proxy2xvpn up
1proxy2xvpn status
```

For changes touching scripts:
```bash
shellcheck scripts/*.sh
bash -n scripts/SCRIPT_NAME.sh   # syntax check
```

For changes touching the middleware:
```bash
cd middleware
pip install -r requirements.txt
ruff check .
python smart_router.py --help
```

### Security-sensitive changes

PRs touching any of the following require explicit security review:

- `docker/iptables_killswitch.sh`
- `docker/entrypoint.sh` (the boot path)
- `docker/Dockerfile`
- `scripts/03_up.sh` (container privileges)
- `middleware/smart_router.py`
- Anything in `observability/` exposing endpoints

Include in your PR description:
- What threat model your change addresses (or risks)
- How you verified no leaks (e.g., `curl -x http://localhost:3100 https://api.ipify.org` shows VPN IP)

---

## Project structure conventions

```
docker/        Container image build context only. No host scripts here.
scripts/       Host-side scripts dispatched by the CLI. Numbered NN_*.sh.
middleware/    Python services that sit alongside HAProxy.
observability/ Compose stack for metrics/logs/alerts.
systemd/       Unit files for production deployment.
docs/          Long-form technical documentation.
ovpns/         User-provided .ovpn files (gitignored).
secrets/       User-provided auth files (gitignored, mode 0600).
```

Do not introduce new top-level directories without discussing first.

---

## Releases

Releases follow [Semantic Versioning](https://semver.org/):

- `MAJOR` — breaking changes to the CLI or container interface
- `MINOR` — new features, backward-compatible
- `PATCH` — bug fixes and documentation

Maintainers tag releases as `vX.Y.Z`, which triggers the multi-arch image build via GitHub Actions.

---

## Questions

For non-bug questions, use GitHub Discussions instead of opening an issue.

Thanks for helping make `1proxy2Xvpn` better.
