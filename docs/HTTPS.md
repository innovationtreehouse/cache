# HTTPS on the cache host (plan)

**Status: not shipped.** Today the client uses HTTP plus the LAN probe in
`linux/lib/common.sh` (`dns_matches_expected` + optional `port_open`). This
note is the plan for putting a public TLS certificate on
`cache.facility.innovationtreehouse.org` **without removing** the check that
the name resolves to `EXPECTED_IP` (`10.41.1.50`).

The cache box is an external dependency (see `README.md`). This repo only
changes how clients talk to it.

## What stays true

- **No public A/AAAA** for `cache.facility.innovationtreehouse.org`. UniFi
  local DNS is the only resolver that answers that name. DHCP DNS stays the
  gateway, not 8.8.8.8.
- **`on_facility` keeps the IP pin.** The FQDN must resolve to exactly
  `EXPECTED_IP`, and pip/npm/apt probes still TCP to that IP (not to
  whichever extra A record a resolver invented). Override the pin in
  `/etc/facility-cache/config` if the box ever moves.
- **apt stays HTTP** on `:3142`. APT's GPG check of `Release`/`Packages` is
  the integrity mechanism; HTTPS on the proxy is optional and not part of
  this plan.

## What HTTPS is for

pip, npm, and Docker currently need `trusted-host` / `allow-insecure-host` /
`insecure-registries` because the cache is plain HTTP. A certificate the
OS already trusts lets those clients use `https://` and drop those
bypasses.

TLS authenticates the **name**. The IP pin authenticates **which box on
this LAN** we meant. They stack; neither replaces the other:

| Situation | IP pin | TLS to the FQDN |
|---|---|---|
| Off-site, name NXDOMAINs | Fail | Fail |
| Another LAN with a host at the same IP, name does not resolve | Fail | Fail |
| DNS poisoned so the name is `.200` but that is not our host | Pass | Fail (no private key) |
| DNS poisoned to some other IP | Fail | Fail (wrong/no cert) |
| ARP spoof of `.200` without the key | Pass | Fail |
| PEMs copied onto the wrong machine, UniFi still points at `.200` | Fail | Would pass if the client skipped the pin |
| Real cache host compromised, or the key stolen and used on `.200` | Pass | Pass |

The last row is **not** a TLS problem. A stolen or in-use key means pip and
Docker will trust the channel. Content authentication is separate: apt
already has GPG; pip that matters needs lockfile hashes; Docker should pin
digests or not use the Hub mirror. HTTPS + the IP pin do not substitute for
that.

## Certificate

Issue a **public** cert for `cache.facility.innovationtreehouse.org` (no
wildcard). Clients must not need a facility CA.

**AWS ACM exportable public certificate** (Allow export enabled at request
time; older ACM certs cannot be exported later):

1. DNS-validate in the public `innovationtreehouse.org` zone (ACM CNAME
   only). Do not create a public A record for the cache name.
2. Export PEM + chain + encrypted key. Decrypt only on `.200`, mode `600`.
   Never commit the key.
3. ACM renews **in ACM**. A job must re-export and reload the proxy before
   expiry (~395 days).

**Let's Encrypt DNS-01 via Route53 on the box** is the lower-toil variant:
same public trust, no public A record, renew in place, no export step.

Do not use ACM Private CA for this unless every laptop is going to trust a
custom CA.

## On the box

Terminate TLS on `.200` in front of the HTTP backends (Caddy or nginx, or
the registry's own TLS). Same cert on every HTTPS port. Firewall still
LAN-only, no NAT, no VPN export of that zone.

| Port | Backend | After this plan |
|---|---|---|
| 3142 | apt-cacher-ng | HTTP (unchanged) |
| 3141 | PyPI / devpi | HTTPS |
| 4873 | verdaccio | HTTPS |
| 5000 | Docker Hub pull-through | HTTPS |
| 5001 | GHCR pull-through | HTTPS |

Keep the port numbers. Do not serve HTTP and HTTPS on the same port.

## Client changes (a later release in this repo)

`defaults.env` / `defaults.json` and the URL helpers in `common.sh` /
`FacilityCache.psm1` switch those four endpoints to `https://`. Then:

- **pip / uv** — stop writing `trusted-host` / `allow-insecure-host`.
  `on_facility "$PYPI_PORT"` stays (DNS is `.200` and TCP :3141 answers;
  TLS is after TCP).
- **npm** — registry URL `https://…:4873/`. Same probe.
- **Docker** — `registry-mirrors` becomes `https://host:5000` (and GHCR
  likewise). **Remove `insecure-registries`.** Docker still does not use
  `on_facility`; off-site safety remains “the name does not resolve.”
- **apt** — still `on_facility "$APT_PORT"` then HTTP proxy or `DIRECT`.

Until that release ships, the box can speak HTTPS on new listeners while
old clients keep HTTP on the old ports.

## Probe (unchanged)

```
on_facility [port]
  → dns_matches_expected   # CACHE_HOST A records include EXPECTED_IP
  → port_open EXPECTED_IP  # TCP to the pin, not to the hostname
```

Do not retarget `port_open` at the hostname, and do not replace this with
“TLS handshake succeeded” in the same change. A later hardening can add a
TLS probe for HTTPS tools; apt stays on the IP/port check until :3142 is
wrapped.

If the cache box's address changes: set `EXPECTED_IP` in
`/etc/facility-cache/config` (and Windows `config.json`) on each machine,
or ship a client release that updates `defaults.*`.

## Rollout

1. Cert issued and loaded on `.200` for 3141/4873/5000/5001. Confirm
   `openssl s_client -connect 10.41.1.50:3141 -servername cache.facility.innovationtreehouse.org`
   from a LAN host, and NXDOMAIN for that name off-site.
2. Client release: `https://` URLs, drop the HTTP bypasses, **keep**
   `EXPECTED_IP`.
3. Only after (2) is on the fleet, turn off HTTP on those four ports.
