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
  `10.41.1.50` **and** the pypi port answers). Off-site, those files and
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
Release. Clients with `gh` then verify the downloaded archive in two steps:

1. Fetch every attestation for the file's SHA-256 from the **public**
   GitHub attestations API — no credentials of any kind required for a
   public repo:

   ```
   GET https://api.github.com/repos/innovationtreehouse/cache/attestations/sha256:<sha256 of FILE>
   ```

   Write each returned `attestations[i].bundle` out as its own line of a
   JSON Lines file (`gh attestation verify --bundle` accepts one bundle
   object per line). As cheap extra hardening, any attestation whose own
   `repository_id` doesn't match the pinned numeric repo id is dropped
   before this step, when that id is known.
2. Verify that bundle file without any further GitHub API calls and
   without a `gh login` — `gh` still consults Sigstore's public TUF root
   over the network the first time its local cache is cold, so "offline"
   here means no GitHub API/auth dependency, not "no network at all":

   ```
   gh attestation verify FILE --repo innovationtreehouse/cache \
     --bundle bundle.jsonl \
     --signer-workflow innovationtreehouse/cache/.github/workflows/release.yml \
     --deny-self-hosted-runners
   ```

**This document and this client used to call the bare
`gh attestation verify FILE --repo ... --signer-workflow ...` form
directly (no `--bundle`) — that was wrong.** That form always requires an
authenticated `gh` (`gh auth login`, or `GH_TOKEN`/`GITHUB_TOKEN` set) even
against a fully public repo. The updater runs unattended as SYSTEM
(Windows scheduled task) / root (systemd), which is never `gh auth login`'d,
so it was silently exiting 4 ("please run: gh auth login") on every single
run and quietly falling back to SHA-256-only — the "attestation
unavailable" warning fired unconditionally and nobody could tell from the
logs. The two-step bundle form above is what the client actually runs now,
and it genuinely requires zero credentials. If a token happens to be
configured (`github-token` file, `GITHUB_TOKEN` env var, or `GitHubToken`
in Windows `config.json`), it is attached only to the bundle-fetch GET in
step 1, purely to lift GitHub's unauthenticated 60 requests/hour/IP rate
limit on that endpoint — it is never required and never gates whether
verification runs.

`--signer-workflow` so a different workflow in the repo with
`attestations: write` cannot satisfy the check.
`--deny-self-hosted-runners` so only GitHub-hosted runners count.

Both updaters (`linux/sbin/facility-cache-update`,
`windows/FacilityCache.psm1`) and both bootstraps (`linux/bootstrap.sh`,
`windows/Install-FromGitHub.ps1`) run that two-step check when `gh` is on
PATH. It is a best-effort layer on top of SHA-256, not a replacement: if
`gh` isn't installed, the bundle can't be fetched (offline, rate-limited,
no attestation published, repo not public yet), or the `gh` call fails for
any reason, the client logs a warning and falls back to SHA-256 alone, so
a fleet without `gh` (or without network access to GitHub's attestations
API) never bricks. A hard-fail mode (refuse to install without a verified
attestation) is a deliberate future option once attestations have been
live long enough to trust as a hard gate.

`windows/Install-FromGitHub.ps1` carries its own copy of the verifier
(~35 duplicated lines) rather than importing it from the release zip it is
verifying: sourcing the checker from the archive under test would let a
malicious release ship a module whose check always passes, or omit it to
skip verification entirely. That duplication is intentional. The bundle
check there also runs before the zip is ever extracted or its module
imported, for the same reason. `linux/bootstrap.sh` doesn't have that
problem the same way — its check is inline shell/Python from the start,
not sourced from the tarball.

Free GitHub Artifact Attestations require the repo to be **public** (or GitHub
Enterprise Cloud with the add-on). If `innovationtreehouse/cache` ever goes
private, re-check this before assuming attestation verification still works.

## GitHub CLI on client machines

Bootstrap, `install.sh`, and the daily updater **install `gh` if it is
missing** and **upgrade it** when a newer version is in GitHub's apt repo
(Ubuntu) or winget / GitHub Releases (Windows). Attestation stays
warn-only if that install fails, so a machine without `gh` is weaker, not
bricked.

Ubuntu uses GitHub's apt repository (GPG keyring under
`/etc/apt/keyrings/facility-cache-githubcli.gpg`), not Ubuntu universe
(too old for `--signer-workflow`) and not `curl | bash`. On the facility
LAN the source line is rewritten through apt-cacher-ng:

```
http://cache.facility.innovationtreehouse.org:3142/https://cli.github.com/packages
```

`facility-apt-proxy` returns `DIRECT` for URLs already aimed at the cache
host so that rewrite is not double-proxied. Off-site the source is
`https://cli.github.com/packages`. Apply (every 5 minutes) only rewrites
the URL; install/update/bootstrap run `apt-get install gh`.

Windows: `winget install`/`upgrade GitHub.cli`, falling back to the
`windows_amd64.msi` from `cli/cli` releases. There is no apt-cacher-ng
equivalent for that path.

Uninstall removes the apt source and keyring this client wrote; it does
not remove `gh` itself.

No `gh auth login` is required for this public repo — the client only
ever calls `gh attestation verify` in the two-step `--bundle` form
described above, which needs no login. **The bare
`gh attestation verify FILE --repo ... --signer-workflow ...` form shown
in older docs, or run ad hoc by a human, does need `gh auth login` /
`GH_TOKEN` first** — that requirement is a property of the bare form
itself, not of this repo being public. See `README.md` for the two-step
commands to run that ad hoc check without logging in.

Recommended first install still verifies `install-linux.sh` /
`install-windows.ps1` **before** executing them — that needs a `gh`
already on PATH. `curl | sudo bash` cannot do that; it installs `gh`
from the tarball, then attests the archive. See `README.md`.

## Release-publishing controls

`release.yml` only publishes from a `vX.Y.Z` tag ref whose value matches
`VERSION` — a plain `workflow_dispatch` from a branch can no longer publish
unguarded (see the workflow for the exact guard).

That guard controls *what* gets published; it doesn't control *who* can push
a matching tag. Restricting who may push tags matching `v*` is a **GitHub
repository ruleset** (Settings → Rules → Rulesets → tag ruleset, or the
equivalent API), not a file in this repo. Apply one before treating tag-push
as a trusted release trigger.
