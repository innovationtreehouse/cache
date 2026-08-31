#!/bin/bash
# Linux client end-to-end harness. Runs INSIDE the client container as root.
# The repo is mounted read-only at /repo. The fake cache is reachable as
# cache.facility.innovationtreehouse.org -> 172.28.0.50 on the fixture network.
set -u
PASS=0
FAIL=0
ck() { # ck <name> <exit-status> [detail]
  if [ "$2" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "PASS  $1  ${3:-}"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL  $1  ${3:-}"
  fi
}
sec() {
  echo
  echo "##### $1"
}
EXP_IP=172.28.0.50
FQDN=cache.facility.innovationtreehouse.org

write_config() { # write_config [extra lines...]
  {
    printf 'EXPECTED_IP=%s\n' "$EXP_IP"
    [ -n "${GITHUB_TOKEN:-}" ] && printf 'GITHUB_TOKEN=%s\n' "$GITHUB_TOKEN"
    for line in "$@"; do printf '%s\n' "$line"; done
  } >/etc/facility-cache/config
}

sec "T0 environment"
[ "$(ps -p 1 -o comm=)" = systemd ]
ck "systemd is PID 1" $?
getent ahostsv4 "$FQDN" | grep -q "$EXP_IP"
ck "FQDN resolves to $EXP_IP" $?

sec "T1 pre-seed: local config override + pre-existing docker daemon.json"
mkdir -p /etc/facility-cache /etc/docker
write_config
printf '{\n  "debug": true,\n  "registry-mirrors": ["https://mirror.example.com"]\n}\n' >/etc/docker/daemon.json
ck "seeded" 0

sec "T2 install.sh (real systemctl; gh via apt THROUGH the cache proxy on empty apt lists)"
# A Windows checkout mounts with CRLF; git stores LF and the release tarball
# ships LF, so normalize to what a real Linux client receives. No-op on LF.
rm -rf /opt/src && cp -r /repo /opt/src && find /opt/src -type f ! -path '*/.git/*' -exec sed -i 's/\r$//' {} + && bash /opt/src/linux/install.sh
ck "install.sh exit 0" $?
for f in /usr/local/bin/facility-cache /usr/local/bin/facility-cache-probe /usr/local/bin/facility-apt-proxy \
  /usr/local/sbin/facility-cache-apply /usr/local/sbin/facility-cache-update /usr/local/sbin/facility-cache-uninstall \
  /usr/local/lib/facility-cache/common.sh /usr/local/lib/facility-cache/defaults /usr/local/lib/facility-cache/VERSION \
  /etc/apt/apt.conf.d/00facility-cache /etc/profile.d/facility-cache.sh; do
  [ -e "$f" ]
  ck "installed: $f" $?
done
systemctl is-enabled --quiet facility-cache-apply.timer
ck "apply.timer enabled" $?
systemctl is-active --quiet facility-cache-apply.timer
ck "apply.timer active" $?
systemctl is-enabled --quiet facility-cache-update.timer
ck "update.timer enabled" $?
command -v gh >/dev/null
ck "gh installed by install.sh (full-update fallback for empty apt lists)" $? "$(gh --version 2>/dev/null | head -1)"
grep -q "$FQDN:3142" /etc/apt/sources.list.d/facility-cache-github-cli.list 2>/dev/null
ck "gh apt source rewritten through cache (on-site)" $?
python3 -c "import json,sys; d=json.load(open('/etc/docker/daemon.json')); sys.exit(0 if d['registry-mirrors'][0]=='http://$FQDN:5000' and 'https://mirror.example.com' in d['registry-mirrors'] and d['debug'] is True and '$FQDN:5000' in d['insecure-registries'] and '$FQDN:5001' in d['insecure-registries'] else 1)"
ck "daemon.json merged, foreign entries kept" $?
[ -f /etc/docker/daemon.json.facility-cache.bak ]
ck "daemon.json backup written" $?

sec "T3 probe + status (on-site)"
facility-cache probe
ck "probe exit 0" $?
facility-cache probe --port 3141
ck "probe --port 3141 exit 0" $?
OUT="$(facility-cache probe --json)"
echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d['dns_ok'] and '$EXP_IP' in d['resolved'] else 1)"
ck "probe --json dns_ok" $? "$OUT"
facility-cache status | tee /tmp/status1 >/dev/null
ck "status exit 0" $?
grep -q "on-site" /tmp/status1
ck "status shows on-site" $?
facility-cache version >/dev/null
ck "version exit 0" $?

sec "T4 apply drop-ins (on-site)"
/usr/local/sbin/facility-cache-apply
ck "apply exit 0" $?
grep -q "index-url = http://$FQDN:3141/root/pypi/+simple/" /etc/pip.conf
ck "pip.conf index-url" $?
head -1 /etc/pip.conf | grep -q facility-cache-managed
ck "pip.conf managed marker" $?
grep -q "allow-insecure-host" /etc/uv/uv.toml
ck "uv.toml written" $?
grep -q "registry=http://$FQDN:4873/" /etc/npmrc
ck "npmrc registry" $?
grep -q "PIP_INDEX_URL" /run/facility-cache/env
ck "/run env file" $?
grep -q "PIP_INDEX_URL" /etc/environment.d/60-facility-cache.conf
ck "environment.d drop-in" $?

sec "T5 real traffic through the ubuntu cache"
/usr/local/bin/facility-apt-proxy http://archive.ubuntu.com/ubuntu | head -1 | grep -q "http://$FQDN:3142"
ck "apt proxy auto-detect -> cache" $?
/usr/local/bin/facility-apt-proxy "http://$FQDN:3142/https://cli.github.com/x" | grep -q DIRECT
ck "apt proxy: cache-addressed URI -> DIRECT (no double-proxy)" $?
apt-get update >/tmp/aptup 2>&1
ck "apt-get update THROUGH cache proxy" $? "$(tail -1 /tmp/aptup)"
apt-get install -y --no-install-recommends sl >/dev/null 2>&1
ck "apt-get install THROUGH cache proxy" $?
pip3 download six --no-deps -d /tmp/pipdl --disable-pip-version-check -q 2>/tmp/piperr
ck "pip download via cache index (devpi path)" $? "$(ls /tmp/pipdl 2>/dev/null | head -1)"
curl -fsS "http://$FQDN:4873/six" -o /tmp/npmmeta && python3 -c "import json;json.load(open('/tmp/npmmeta'))"
ck "npm registry metadata via cache" $?

sec "T6 wrong address (resolves, but not EXPECTED_IP)"
printf 'EXPECTED_IP=10.9.9.9\n' >/etc/facility-cache/config
facility-cache probe
[ $? -eq 1 ]
ck "probe exits 1" $?
/usr/local/sbin/facility-cache-apply
ck "apply exit 0" $?
[ ! -f /etc/pip.conf ]
ck "pip.conf removed" $?
facility-cache status | grep -q "wrong address"
ck "status shows wrong address" $?

sec "T7 off-site (NXDOMAIN)"
printf 'CACHE_HOST=cache.nonexistent-offsite.invalid\nEXPECTED_IP=%s\n' "$EXP_IP" >/etc/facility-cache/config
facility-cache probe
[ $? -eq 1 ]
ck "probe exits 1" $?
/usr/local/sbin/facility-cache-apply
ck "apply exit 0" $?
[ ! -f /etc/npmrc ] && [ ! -f /etc/uv/uv.toml ]
ck "drop-ins removed" $?
[ ! -f /etc/environment.d/60-facility-cache.conf ]
ck "environment.d removed" $?
/usr/local/bin/facility-apt-proxy http://archive.ubuntu.com/ubuntu | grep -q DIRECT
ck "apt proxy -> DIRECT off-site" $?
apt-get update >/dev/null 2>&1
ck "apt-get update DIRECT off-site" $?
facility-cache status | grep -q "off-site"
ck "status shows off-site" $?

sec "T8 back on-site; unmanaged file protection"
write_config
printf '[global]\nindex-url = https://corp.example/simple\n' >/etc/pip.conf
/usr/local/sbin/facility-cache-apply
ck "apply exit 0" $?
grep -q corp.example /etc/pip.conf
ck "foreign /etc/pip.conf untouched" $?
grep -q "index-url = http://$FQDN:3141" /etc/xdg/pip/pip.conf
ck "fallback /etc/xdg/pip/pip.conf used instead" $?
rm -f /etc/pip.conf
/usr/local/sbin/facility-cache-apply >/dev/null 2>&1

sec "T9 systemd service run (timer's unit)"
systemctl start facility-cache-apply.service
ck "systemctl start apply.service" $?
systemctl is-failed --quiet facility-cache-apply.service
[ $? -ne 0 ]
ck "apply.service not failed" $?

sec "T10 update: --check, repo-id pin refusal, then full update (real GitHub + attestation)"
echo 1.0.0 >/usr/local/lib/facility-cache/VERSION
facility-cache update --check >/tmp/upcheck 2>&1
ck "update --check exit 0" $? "$(grep -Eo 'update available.*' /tmp/upcheck | head -1)"
grep -q "update available" /tmp/upcheck
ck "reports update available (1.0.0 -> latest)" $?
write_config "GITHUB_REPO_ID=999"
facility-cache update --check >/tmp/uppin 2>&1
RC=$?
[ "$RC" -ne 0 ] || ! grep -q "update available" /tmp/uppin
ck "repo-id pin mismatch refuses (negative)" $? "$(grep -iEo 'refus[^\"]*|mismatch[^\"]*' /tmp/uppin | head -1)"
write_config
facility-cache update >/tmp/upfull 2>&1
ck "full update exit 0" $? "$(tail -2 /tmp/upfull | head -1)"
grep -Eq "verified" /tmp/upfull
ck "attestation VERIFIED (no gh login)" $? "$(grep -E 'attest|verified|sha256 only' /tmp/upfull | tail -1)"
V="$(cat /usr/local/lib/facility-cache/VERSION)"
[ "$V" != "1.0.0" ]
ck "VERSION advanced after update" $? "now $V"
python3 -c "import json,sys; st=json.load(open('/var/lib/facility-cache/state.json')); sys.exit(0 if st.get('last_result')=='updated' else 1)"
ck "state.json last_result=updated" $?
facility-cache log -n 5 >/dev/null 2>&1
ck "facility-cache log" $?
facility-cache log --json >/dev/null 2>&1
ck "facility-cache log --json" $?

sec "T11 uninstall"
facility-cache uninstall
ck "uninstall exit 0" $?
[ ! -e /usr/local/sbin/facility-cache-apply ] && [ ! -e /usr/local/bin/facility-cache ] && [ ! -d /usr/local/lib/facility-cache ]
ck "binaries removed" $?
[ ! -e /etc/apt/apt.conf.d/00facility-cache ]
ck "apt conf removed" $?
systemctl is-enabled --quiet facility-cache-apply.timer 2>/dev/null
[ $? -ne 0 ]
ck "timers unregistered" $?
python3 -c "import json,sys; d=json.load(open('/etc/docker/daemon.json')); sys.exit(0 if d=={'debug':True,'registry-mirrors':['https://mirror.example.com']} else 1)"
ck "daemon.json restored from backup" $?
[ -f /etc/docker/daemon.json.facility-cache.uninstalled ]
ck "pre-restore snapshot kept" $?
[ -f /etc/facility-cache/config ]
ck "local config left in place" $?
[ ! -f /etc/xdg/pip/pip.conf ] && [ ! -f /etc/npmrc ]
ck "managed drop-ins removed" $?

echo
echo "RESULT pass=$PASS fail=$FAIL"
exit "$FAIL"
