# Facility cache client

Points Ubuntu and Windows machines at `cache.facility.innovationtreehouse.org` **only while they are on the facility LAN**. Off-site, the hostname does not resolve in public DNS, so clients go direct to Ubuntu/PyPI/npm/Docker Hub/Microsoft.

Never uses `10.41.1.50` or the short name `cache` in client config (those collide on other networks). The probe requires the FQDN to resolve to **exactly** `10.41.1.50`.

Installed clients **update themselves from GitHub Releases**. A new tag publishes new scripts *and* new package defaults (host, ports, repo). Local override files are not overwritten.

Default repo: `innovationtreehouse/cache`.

The cache host itself (`10.41.1.50`, apt-cacher-ng/devpi/verdaccio/Docker mirrors on ports 3141-5001) is an **external dependency**: this repo only configures clients to find it, it does not provision or run that box. See the org's infra repo for how the cache host is built and kept up.

## What gets applied

| Client | On facility | Off-site |
|---|---|---|
| apt (Ubuntu) | HTTP proxy `…:3142` via APT auto-detect | `DIRECT` |
| pip / uv | index-url `…:3141/root/pypi/+simple/` | files/env removed; public PyPI |
| npm | registry `…:4873` | default registry.npmjs.org |
| Docker Hub | `registry-mirrors` (always listed) | engine falls back to docker.io |
| GHCR | not rewritten | pull `ghcr.io/...` as usual |
| Windows Update / Store | DHCP option **235** → MCC, if you deploy one | option absent → Microsoft CDN |
| Microsoft 365 Apps / Defender updates | *partly* Delivery-Optimization-backed at best | expect some direct-to-Microsoft traffic regardless |

> Delivery Optimization only honors the DHCP option 235 cache host on Windows Pro/Enterprise/Education. **Windows Home ignores that policy entirely** and always goes straight to Microsoft's CDN — there is no workaround for that edition here.

## GitHub CLI on client machines

First install and the daily updater install `gh` if it is missing, and
upgrade it when GitHub's apt repo / winget has a newer version. On the
facility LAN the Ubuntu package is fetched through apt-cacher-ng
(`http://cache…:3142/https://cli.github.com/packages`) so later machines
reuse the cached `.deb`. Off-site, and on Windows (winget or the GitHub
Releases MSI), it is a direct GitHub download.

No `gh auth login` is required for this public repo. If `gh` still cannot
be installed, SHA-256 still runs and attestations stay warn-only. Details:
[`docs/SECURITY.md`](docs/SECURITY.md).

## Ubuntu — first install from a Release

`innovationtreehouse/cache` is a public repo — no token, no `gh auth login`.
Download, verify the bootstrap script, then run it:

```bash
curl -fsSL -o install-linux.sh \
  https://github.com/innovationtreehouse/cache/releases/latest/download/install-linux.sh
gh attestation verify install-linux.sh --repo innovationtreehouse/cache \
  --signer-workflow innovationtreehouse/cache/.github/workflows/release.yml \
  --deny-self-hosted-runners
sudo bash install-linux.sh
facility-cache status
facility-cache version
```

`curl | sudo bash` still works and skips verifying the bootstrap script
before it runs. The script installs `gh` if needed, then attests the
tarball it downloaded.

From a git checkout instead:

```bash
sudo ./linux/install.sh
```

Options: `--no-docker`, `--no-restart-docker`.

Uninstall (installed clients don't need the checkout — `uninstall.sh` ships to `/usr/local/sbin/facility-cache-uninstall`):

```bash
sudo facility-cache uninstall
sudo facility-cache uninstall --keep-docker
```

Client files, timers, and drop-ins are removed. `/etc/facility-cache/config` and the event log under `/var/log/facility-cache/` are left in place.

If install found a `daemon.json.facility-cache.bak`, uninstall restores it exactly — whatever was live in `daemon.json` right before that restore (our entries, plus any manual edits made since install) is saved first to `daemon.json.facility-cache.uninstalled`, so nothing is silently lost.

Local overrides (kept across updates): `/etc/facility-cache/config`

`/etc/facility-cache/github-token` (mode 600) is **only needed if this repo ever goes private again** — but if the file exists, its contents are still sent as a bearer token on every GitHub API call. Delete it if it's stale or you don't need it; a bad token in there will break updates even on a public repo.

A 5-minute timer re-applies LAN detection. A **daily** timer (with jitter) checks GitHub for a newer release, verifies `manifest.json` SHA-256 (and GitHub Artifact Attestations if `gh` is on PATH), and re-runs `install.sh` without restarting Docker. See `docs/SECURITY.md` for the self-update integrity/authenticity model in full.

Commands draw a live terminal dashboard (steps, bars, on/off glyphs). The same events are appended as JSON lines you can fetch later:

```bash
sudo facility-cache update          # install if newer
sudo facility-cache update --check  # print versions only
sudo facility-cache update --force  # reinstall current latest
facility-cache log                  # last 40 events, pretty
facility-cache log -n 100 -f        # follow
facility-cache log --json           # machine-readable
facility-cache log --path           # where the file lives
```

## Windows — first install from a Release

Elevated PowerShell. Same public-repo, no-auth model as Linux — no token needed.
Verify the bootstrap script before executing it:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Invoke-WebRequest -UseBasicParsing `
  https://github.com/innovationtreehouse/cache/releases/latest/download/install-windows.ps1 `
  -OutFile install-windows.ps1
gh attestation verify .\install-windows.ps1 --repo innovationtreehouse/cache `
  --signer-workflow innovationtreehouse/cache/.github/workflows/release.yml `
  --deny-self-hosted-runners
.\install-windows.ps1
```

From a checkout:

```powershell
.\windows\Install-FacilityCache.ps1
.\windows\Status-FacilityCache.ps1
```

Uninstall:

```powershell
.\windows\Uninstall-FacilityCache.ps1
```

Scheduled tasks and drop-ins are removed; `config.json` and the event log under `logs\` are preserved.

Local overrides: `C:\ProgramData\FacilityCache\config.json` (start from `{}`).
Package defaults: `C:\ProgramData\FacilityCache\defaults.json` (replaced on each release).
`C:\ProgramData\FacilityCache\github-token` is **only needed if this repo ever goes private again** — but if it exists, it's still sent as a bearer token on every call. Delete it if it's stale; a bad token breaks updates even on a public repo.

Scheduled tasks: `FacilityCache-Apply` (LAN, every 5 minutes) and `FacilityCache-Update` (GitHub, daily + at boot).

```powershell
& "$env:ProgramData\FacilityCache\FacilityCache-Update.ps1" -Check
& "$env:ProgramData\FacilityCache\FacilityCache-Update.ps1" -Force
Import-Module "$env:ProgramData\FacilityCache\FacilityCache.psm1"
Show-FacilityCacheDashboard
Show-FacilityCacheLog
Show-FacilityCacheLog -PathOnly
```

## Publishing a release

1. Bump `VERSION` (semver, no `v` prefix).
2. Change `defaults.env` / `defaults.json` if host, ports, or repo should move.
3. Tag and push:

```bash
git tag v1.0.1
git push origin v1.0.1
```

GitHub Actions packs:

- `facility-cache-client-linux.tar.gz`
- `facility-cache-client-windows.zip`
- `manifest.json` (version + SHA-256)
- `SHA256SUMS`
- `install-linux.sh` / `install-windows.ps1`

Each of those files is attested (build provenance from `release.yml`) before
the Release is published. Clients with `gh` verify the archive they download.
See `docs/SECURITY.md`. Clients pick a new release up on the next daily check
(or immediately with `facility-cache update`).

Pack locally without tagging: `python3 scripts/pack-release.py`

## UniFi (once, on the facility DHCP)

1. Local DNS: `cache.facility.innovationtreehouse.org` → `10.41.1.50`
2. DHCP DNS = the gateway (`10.41.1.1`), not 8.8.8.8
3. Custom DHCP option **235** (text) = `cache.facility.innovationtreehouse.org`
4. Do **not** publish a public A record for that name

## Notes

- Do not set a machine-wide `http_proxy`.
- Do not put a static `Acquire::http::Proxy` in apt; auto-detect is the fallback.
- Auto-update talks to GitHub, not the facility cache, so it still works off-site.
- Auto-update does **not** restart Docker; restart it yourself if `daemon.json` changed.
- Disable auto-update: `AUTO_UPDATE=0` in `/etc/facility-cache/config`, or `"AutoUpdate": false` in the Windows `config.json`.
- Existing `/etc/pip.conf` or `/etc/npmrc` without a `facility-cache-managed` marker is left alone.
- Docker's `registry-mirrors` / `insecure-registries` are written once at install/update time and **stay in `daemon.json` off-site too** — unlike pip/npm/uv they are not toggled on network change. dockerd only reads `daemon.json` at start (or a `docker restart docker`), so gating them on the LAN probe would mean restarting the daemon every time the network changes. Entries are always exact `host:port` strings (never a bare hostname or wildcard), so this only affects pulls explicitly addressed to that host:port — accepted trade-off for the trusted-LAN model.
- Changing `CACHE_HOST` between releases only *adds* the new host's entries to `daemon.json` — it does not remove the old host's. Old-host entries accumulate until something explicitly restores/edits `daemon.json` (uninstall's backup-restore does this; a plain update does not).
- Trust model, integrity checks, and release-publishing controls: see [`docs/SECURITY.md`](docs/SECURITY.md).
- Planned HTTPS on the cache host (public cert, keep the `.200` IP pin, drop `trusted-host` / `insecure-registries`): [`docs/HTTPS.md`](docs/HTTPS.md).
