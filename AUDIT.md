# Security review

Review date: 2026-09-30.

Audited inputs:

- local `start-script.sh`;
- `mozaroc/3x-ui-pro` assets at commit
  `a2c430cd6dec7c86d873dcda3544a61e7ac41144`;
- official `MHSanaei/3x-ui` installer at commit
  `99047c0a6394af4f74a3105220f2910ef615dce8`.

## Conclusion

No deliberate backdoor was found in the reviewed shell, Python, HTML, or
JavaScript sources. This is not proof that prebuilt 3x-ui/Xray binaries are
backdoor-free: those binaries were not reverse-engineered or reproduced from
source in this review.

The original installer nevertheless had a remote-code supply-chain path:
`mtr-backend.py` was downloaded from a mutable `main` branch without a digest
and installed as a persistent systemd service with `CAP_NET_RAW`. A repository
takeover or later malicious commit would therefore become code execution on the
next installation. The browser assets and Clash template were mutable for the
same reason, although their impact differs.

## Findings and remediation

### High: arbitrary loopback proxy through nginx — fixed

The regex route accepted a client-controlled decimal port and proxied requests
to `127.0.0.1:$port`. Anyone able to reach the public vhost could scan or talk
to local-only HTTP/gRPC services. It was replaced with two fixed routes for the
generated WS and Trojan ports.

### High: mutable unauthenticated application assets — fixed

All former `GITHUB_RAW` assets are now vendored under `assets/` and verified
against `assets/SHA256SUMS` before system files are changed. The Python backend
contains no `shell=True`; MTR arguments are passed as an array after strict IP
validation, it listens only on loopback, and its systemd sandbox remains in
place.

### High: destructive nginx/uninstall behavior — fixed

The old code deleted all `sites-enabled`, `sites-available`, nginx configuration,
and nginx packages. Cleanup now targets only installer-owned paths. An existing
3x-ui SQLite database is copied to a root-only timestamped backup before a clean
reinstall.

### Medium: 3x-ui release integrity/version skew — fixed

The archive is verified with the release `.sha256` sidecar or an operator-pinned
`PANEL_SHA256`. `/usr/bin/x-ui` is installed from that same verified archive,
instead of taking `x-ui.sh` from a different mutable branch. Explicit release
pinning with `-version` remains recommended.

### Medium: root-level configuration injection — fixed

Panel and REALITY domains previously flowed into nginx and SQLite templates
without strict validation. Both must now be lowercase-valid FQDNs before any
destructive installation step.

### Medium: unrelated service and cron modification — fixed

The installer no longer kills arbitrary listeners on ports 80/443, disables UFW
during package installation, rewrites root's crontab, or assumes SSH uses port
22. Certificate renewal lives in a dedicated `/etc/cron.d/3x-ui-pro` file.

### Medium: partial database writes — fixed

Settings use idempotent upserts, and the generated inbounds/hosts are applied in
one SQLite transaction with `.bail on`; a schema error rolls back instead of
leaving a half-configured panel.

## Remaining trust and network dependencies

- Distribution package repositories and their signing infrastructure.
- GitHub release hosting for the selected 3x-ui archive and checksum. For the
  strongest available mode, pin both `-version` and `PANEL_SHA256` out of band.
- Let's Encrypt and DNS for certificate issuance.
- `ipv4.icanhazip.com` / `ipv6.icanhazip.com` only when route-based local address
  discovery fails.
- Remote DNS, health-check URLs, icons, and rule providers referenced by the
  generated Clash configuration. These are client-side policy dependencies and
  are not executed by the server installer.

## Recommended next hardening pass

1. Replace external Clash rule providers with locally mirrored, digest-pinned
   rule sets if fully offline client policy is required.
2. Add a non-destructive upgrade mode that preserves the database and generated
   secrets rather than treating every install as a rebuild.
3. Persist an installer-owned state manifest so uninstall can remove vhost files
   even when domains are not supplied again.
4. Run an integration test on disposable Debian and Ubuntu VMs before production;
   static checks cannot validate systemd, nginx modules, ACME, or the live 3x-ui
   database schema.
