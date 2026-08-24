# Trust model

## What this proxies, and what it doesn't

Every cache/mirror this client points at — apt-cacher-ng, devpi/pip, verdaccio,
the Docker Hub pull-through — serves **public package content only**: the same
bytes anyone gets from Ubuntu/PyPI/npm/Docker Hub directly. No private
package feeds, no credentials, no build artifacts flow through the facility
cache. Compromising the cache host lets an attacker serve stale or malicious
*public* packages to on-facility machines; it does not expose anything this
repo's clients weren't already going to fetch from the public internet.

## LAN trust, not transport security

Traffic to the cache host (`cache.facility.innovationtreehouse.org`) is plain
HTTP, on the facility LAN, by design — not HTTPS. That's a deliberate
LAN-trust boundary: the facility network is treated as trusted transport, the
same way a corporate office trusts its own switches. Do not extend reachability
to that host beyond the facility LAN (no site-to-site VPN routing, no NAT
forwarding it in) without revisiting this assumption — this repo's DNS design
(the FQDN doesn't resolve off-site, see `README.md`) is the control that keeps
it LAN-only today, and it's a DNS-based control, not a network ACL.

Putting a public TLS certificate on the cache host (and dropping pip/Docker
HTTP bypasses) is a planned follow-up. The client will keep requiring that
the FQDN resolve to `EXPECTED_IP`. See [`HTTPS.md`](HTTPS.md).

## Integrity, package by package

- **apt** — untouched. `Acquire::http::Proxy-Auto-Detect` only changes *where*
  packages are fetched from; APT's own GPG signature verification of
  `Release`/`Packages` still runs regardless of proxy. A compromised cache
  cannot push an unsigned or mis-signed `.deb`.
- **pip / uv** — the `trusted-host` / `allow-insecure-host` bypass (needed
  because the cache serves plain HTTP) is written by `facility-cache-apply`
  *only* while the LAN probe confirms we're on-site (DNS matches
  `192.168.1.200` **and** the pypi port answers). Off-site, those files and
  env vars are removed. The insecure-TLS window is gated to exactly when the
  cache is actually reachable, not left on unconditionally.
- **Docker** — `registry-mirrors` and `insecure-registries` in `daemon.json`
  are **not** LAN-gated like pip/npm are: they're written once at install
  time and stay in place regardless of current network. That's intentional,
  not an oversight — toggling them would require a Docker daemon restart on
  every network change, which this repo explicitly avoids. It's safe because
  the entries only *name* the facility hostname; off-site that hostname does
  not resolve in public DNS, so the insecure-registry config is inert
  (fails closed via DNS) rather than actively insecure off the LAN.

## Self-update authenticity

The daily update timer always verifies the downloaded release tarball/zip
against the SHA-256 in `manifest.json` before installing — that check is
unconditional and always enforced. First-install bootstrap
(`install-linux.sh` / `install-windows.ps1`) does the same for the archive
it downloads.

`release.yml` attests **every file it publishes** with GitHub Artifact
Attestations (`actions/attest-build-provenance`):

- `facility-cache-client-linux.tar.gz`
- `facility-cache-client-windows.zip`
- `manifest.json`
- `SHA256SUMS`
- `install-linux.sh`
- `install-windows.ps1`

That is a Sigstore-backed record that those bytes were produced by this
repo's `release.yml` on a GitHub-hosted runner, not hand-uploaded onto a
Release. Clients with `gh` then verify the downloaded archive:

```
gh attestation verify FILE --repo innovationtreehouse/cache \
  --signer-workflow innovationtreehouse/cache/.github/workflows/release.yml \
  --deny-self-hosted-runners
```

`--signer-workflow` so a different workflow in the repo with
`attestations: write` cannot satisfy the check.
`--deny-self-hosted-runners` so only GitHub-hosted runners count.

Both updaters (`linux/sbin/facility-cache-update`,
`windows/FacilityCache.psm1`) and both bootstraps run that check when `gh`
is on PATH. It is a best-effort layer on top of SHA-256, not a replacement:
if `gh` isn't installed or the check fails for any reason (offline,
rate-limited, repo not public yet), the client logs a warning and falls
back to SHA-256 alone, so a fleet without `gh` never bricks. A hard-fail
mode (refuse to install without a verified attestation) is a deliberate
future option once attestations have been live long enough to trust as a
hard gate.

Free GitHub Artifact Attestations require the repo to be **public** (or GitHub
Enterprise Cloud with the add-on). If `innovationtreehouse/cache` ever goes
private, re-check this before assuming attestation verification still works.

## Release-publishing controls

`release.yml` only publishes from a `vX.Y.Z` tag ref whose value matches
`VERSION` — a plain `workflow_dispatch` from a branch can no longer publish
unguarded (see the workflow for the exact guard).

That guard controls *what* gets published; it doesn't control *who* can push
a matching tag. Restricting who may push tags matching `v*` is a **GitHub
repository ruleset** (Settings → Rules → Rulesets → tag ruleset, or the
equivalent API), not a file in this repo. Apply one before treating tag-push
as a trusted release trigger.
