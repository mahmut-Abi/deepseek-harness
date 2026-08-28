#!/bin/sh
set -eu

DSH_HOME=${DSH_HOME:-/root/.dsh}
DSH_PORT=${DSH_PORT:-3080}
DSH_PUBLIC_HOST=${DSH_PUBLIC_HOST:-}
DSH_TRUSTED_HOSTS=${DSH_TRUSTED_HOSTS:-}
SEED_HOME=/opt/dsh-home-seed
PROFILE_DIR="$DSH_HOME/profiles/web"

mkdir -p "$DSH_HOME"

# Seed the profile for empty bind mounts, where Docker does not copy image data.
if [ ! -f "$PROFILE_DIR/package.json" ]; then
  cp -an "$SEED_HOME/." "$DSH_HOME/"
fi

if [ ! -f "$DSH_HOME/settings.yaml" ]; then
  printf 'lan-access:\n  enabled: true\n' > "$DSH_HOME/settings.yaml"
elif ! grep -q '^lan-access:' "$DSH_HOME/settings.yaml"; then
  printf '\nlan-access:\n  enabled: true\n' >> "$DSH_HOME/settings.yaml"
fi

rm -f "$DSH_HOME/task-board/ledger-v2.lock"

LAN_IP=${LAN_IP:-}
if [ -z "$LAN_IP" ] && command -v ip >/dev/null 2>&1; then
  LAN_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
fi
if [ -z "$LAN_IP" ] && command -v hostname >/dev/null 2>&1; then
  LAN_IP=$(hostname -I 2>/dev/null | awk '{ print $1 }')
fi

export DSH_HOME DSH_PORT LAN_IP DSH_PUBLIC_HOST DSH_TRUSTED_HOSTS
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/dsh.conf
