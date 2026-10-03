# 3x-ui private installer

Self-contained deployment wrapper for 3x-ui, nginx, TLS, subscriptions, a cover
site, and local network diagnostics. Application assets are stored in `assets/`;
the installer no longer downloads executable code from the former `GITHUB_RAW`
location.

## Recommended invocation

Copy the whole directory to a clean Debian 11–13, Raspbian 11–13, or Ubuntu
20.04/22.04/24.04/26.04 host,
review `AUDIT.md`, then run as root with an explicitly pinned 3x-ui release:

```bash
sudo PANEL_SHA256='<official release archive sha256>' bash ./start-script.sh \
  -version X.Y.Z \
  -subdomain panel.example.com \
  -reality_target www.example.org
```

`-subdomain` is a domain you control; its A/AAAA record must point to the VPS,
because the installer obtains a Let's Encrypt certificate for it.
`-reality_target` (the legacy alias `-reality_domain` also works) is an external
HTTPS camouflage hostname. It must not point to the VPS and does not require a
certificate or DNS ownership on your side. The installer checks its DNS, TLS
1.3 certificate, and HTTP/2 negotiation before changing the existing panel.

Omit `PANEL_SHA256` to use the `.sha256` sidecar published with the selected
GitHub release. Omit `-version` to resolve the latest stable release; explicit
pinning is preferable for reproducible deployments.

Before modifying an asset, update `assets/SHA256SUMS`. Validate locally with:

```bash
bash -n start-script.sh
shellcheck -S warning start-script.sh
(cd assets && sha256sum -c SHA256SUMS)
python3 -m py_compile assets/diagnostics/mtr-backend.py
```

The installer still needs network access for OS packages, Let's Encrypt, public
IP fallback, and the selected official 3x-ui release. Clash clients also fetch
the rule providers listed in `assets/clash/clash.yaml`.

The installation is transactional after the release download: the archive is
checksum-checked, inspected for unsafe paths, and extracted into a staging
directory before the existing panel is stopped. If a later configuration or
health check fails, the previous panel, database, nginx configuration, web
assets, services, renewal hooks, and installer state are restored automatically.

Generated credentials and paths are saved with mode `0600` in
`/etc/3x-ui-pro/state.env`. Panel, subscription, WS, gRPC, diagnostics, and
REALITY backend listeners bind to loopback; only nginx exposes TCP 80/443.
Firewall setup detects all configured sshd ports and refuses to enable a new
UFW policy when it cannot determine a safe SSH port. Set `SSH_PORT=2222` when
installing from cloud-init or a provider console, or `SKIP_FIREWALL=1` to leave
firewall management to the host.

Uninstall using the stored state (no domain arguments are required):

```bash
sudo bash ./start-script.sh -uninstall yes
```

System tuning is isolated in `/etc/sysctl.d/99-3x-ui-pro.conf`, and certificate
renewal uses the distribution's Certbot scheduler plus managed renewal hooks.
The installer does not modify root's crontab.

The script automatically re-executes itself with Bash if it was accidentally
started as `sh start-script.sh`. Other apt/systemd-compatible distributions can
be tested explicitly with `ALLOW_UNSUPPORTED_OS=1`; this bypasses only the OS
allowlist, not dependency or integrity checks.
