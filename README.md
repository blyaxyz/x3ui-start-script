# 3x-ui private installer

Self-contained deployment wrapper for 3x-ui, nginx, TLS, subscriptions, a cover
site, and local network diagnostics. Application assets are stored in `assets/`;
the installer no longer downloads executable code from the former `GITHUB_RAW`
location.

## Recommended invocation

Copy the whole directory to a clean Debian 12/13 or Ubuntu 24.04/26.04 host,
review `AUDIT.md`, then run as root with an explicitly pinned 3x-ui release:

```bash
sudo PANEL_SHA256='<official release archive sha256>' bash ./start-script.sh \
  -version X.Y.Z \
  -subdomain panel.example.com \
  -reality_domain edge.example.com
```

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
