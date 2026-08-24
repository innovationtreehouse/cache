# Facility cache client

Points Ubuntu and Windows machines at `cache.facility.innovationtreehouse.org` **only while they are on the facility LAN**. Off-site, the hostname does not resolve in public DNS, so clients go direct to Ubuntu/PyPI/npm/Docker Hub/Microsoft.

Never uses `192.168.1.200` or the short name `cache` in client config (those collide on other `192.168.1.0/24` networks). The probe requires the FQDN to resolve to **exactly** `192.168.1.200`.

Installed clients **update themselves from GitHub Releases**. A new tag publishes new scripts *and* new package defaults (host, ports, repo). Local override files are not overwritten.

Default repo: `innovationtreehouse/cache`.

## What gets applied

| Client | On facility | Off-site |
|---|---|---|
| apt (Ubuntu) | HTTP proxy `…:3142` via APT auto-detect | `DIRECT` |
| pip / uv | index-url `…:3141/root/pypi/+simple/` | files/env removed; public PyPI |
| npm | registry `…:4873` | default registry.npmjs.org |
| Docker Hub | `registry-mirrors` (always listed) | engine falls back to docker.io |
| GHCR | not rewritten | pull `ghcr.io/...` as usual |
| Windows Update / Store / M365 / Defender | DHCP option **235** → MCC if you deploy it | option absent → Microsoft CDN |

## Ubuntu — first install from a Release

```bash
curl -fsSL https://github.com/innovationtreehouse/cache/releases/latest/download/install-linux.sh | sudo bash
facility-cache status
facility-cache version
```

From a git checkout instead:

```bash
sudo ./linux/install.sh
```

Options: `--no-docker`, `--no-restart-docker`.

Uninstall:

```bash
sudo ./linux/uninstall.sh
sudo ./linux/uninstall.sh --keep-docker
```

Local overrides (kept across updates): `/etc/facility-cache/config`

Private repo token (mode 600): `/etc/facility-cache/github-token`

A 5-minute timer re-applies LAN detection. A **daily** timer (with jitter) checks GitHub for a newer release, verifies `manifest.json` SHA-256, and re-runs `install.sh` without restarting Docker.

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

Elevated PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Invoke-WebRequest -UseBasicParsing `
  https://github.com/innovationtreehouse/cache/releases/latest/download/install-windows.ps1 `
  -OutFile install-windows.ps1
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

Local overrides: `C:\ProgramData\FacilityCache\config.json` (start from `{}`).
Package defaults: `C:\ProgramData\FacilityCache\defaults.json` (replaced on each release).
Private token: `C:\ProgramData\FacilityCache\github-token`

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

and publishes them on the GitHub Release. Clients pick that up on the next daily check (or immediately with `facility-cache update`).

Pack locally without tagging: `python3 scripts/pack-release.py`

## UniFi (once, on the facility DHCP)

1. Local DNS: `cache.facility.innovationtreehouse.org` → `192.168.1.200`
2. DHCP DNS = the gateway (`192.168.1.1`), not 8.8.8.8
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
