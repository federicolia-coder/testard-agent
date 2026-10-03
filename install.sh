#!/bin/sh
# Installs testard-agent, which reports this server's health to Testard.
#
#   curl -fsSL https://raw.githubusercontent.com/federicolia-coder/testard-agent/main/install.sh \
#     | sudo sh -s -- --key tsk_... --url https://platform.testardstudios.it
#
# Read testard-agent first if you like: it's a short shell script that only
# sends numbers and never runs commands from Testard.

set -eu

REPO_RAW="https://raw.githubusercontent.com/federicolia-coder/testard-agent/main"
KEY=""
URL=""

die() { echo "install: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --key) KEY="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root, e.g. with sudo"
[ "$(uname -s)" = "Linux" ] || die "testard-agent supports Linux only"
command -v curl >/dev/null 2>&1 || die "curl is required"
printf '%s' "$KEY" | grep -Eq '^tsk_[A-Za-z0-9_-]{43}$' || die "pass the key from Testard with --key tsk_..."
URL="${URL%/}"
case "$URL" in
  https://*) ;;
  http://localhost*|http://127.0.0.1*) ;; # local testing only
  *) die "pass Testard's address with --url https://..." ;;
esac
printf '%s' "$URL" | grep -Eq '^https?://[A-Za-z0-9.:-]+$' || die "the --url must be just the address, e.g. https://platform.testardstudios.it"

echo "Installing testard-agent..."

# The agent itself. TESTARD_AGENT_SOURCE lets a local copy be used for testing.
if [ -n "${TESTARD_AGENT_SOURCE:-}" ]; then
  install -m 0755 "$TESTARD_AGENT_SOURCE" /usr/local/bin/testard-agent
else
  tmp=$(mktemp)
  curl -fsSL "$REPO_RAW/testard-agent" -o "$tmp" || die "couldn't download testard-agent"
  head -n 1 "$tmp" | grep -q '^#!/bin/sh' || die "downloaded file doesn't look like testard-agent"
  install -m 0755 "$tmp" /usr/local/bin/testard-agent
  rm -f "$tmp"
fi

# A dedicated user with no shell and no home: the agent doesn't need root.
if ! id testard-agent >/dev/null 2>&1; then
  if command -v useradd >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin testard-agent 2>/dev/null \
      || useradd -r -M -s /sbin/nologin testard-agent
  else
    adduser -S -D -H -s /sbin/nologin testard-agent # Alpine
  fi
fi

mkdir -p /etc/testard-agent /var/lib/testard-agent
umask 077
printf 'TESTARD_URL=%s\n' "$URL" > /etc/testard-agent/agent.conf
# The key lives only in this file, readable by the agent's user alone.
printf 'Authorization: Bearer %s\n' "$KEY" > /etc/testard-agent/auth-header
chown -R testard-agent /etc/testard-agent /var/lib/testard-agent
chmod 0600 /etc/testard-agent/auth-header /etc/testard-agent/agent.conf
chmod 0700 /etc/testard-agent /var/lib/testard-agent

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/testard-agent.service <<'UNIT'
[Unit]
Description=Testard agent: report server health
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=testard-agent
ExecStart=/usr/local/bin/testard-agent run
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/testard-agent
UNIT
  cat > /etc/systemd/system/testard-agent.timer <<'UNIT'
[Unit]
Description=Run testard-agent every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now testard-agent.timer >/dev/null
  scheduler="systemd timer"
else
  echo '* * * * * testard-agent /usr/local/bin/testard-agent run >/dev/null 2>&1' > /etc/cron.d/testard-agent
  chmod 0644 /etc/cron.d/testard-agent
  scheduler="cron"
fi

# First report right away, so the server shows up in Testard now.
if su -s /bin/sh testard-agent -c '/usr/local/bin/testard-agent run'; then
  echo "Done. This server now reports to Testard every minute ($scheduler)."
  echo "Check it with: testard-agent status    Remove it with: sudo testard-agent uninstall"
else
  echo "Installed, but the first report failed (see above). It will retry every minute." >&2
  exit 1
fi
