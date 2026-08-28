#!/bin/sh
set -eu

DSH_PORT=${DSH_PORT:-3080}

set -- dsh web --port "$DSH_PORT" --no-open

if [ -n "${LAN_IP:-}" ]; then
  set -- "$@" --trusted-host "$LAN_IP:$DSH_PORT"
fi

if [ -n "${DSH_PUBLIC_HOST:-}" ]; then
  set -- "$@" --trusted-host "$DSH_PUBLIC_HOST"
fi

if [ -n "${DSH_TRUSTED_HOSTS:-}" ]; then
  old_ifs=$IFS
  IFS=', '
  for trusted_host in $DSH_TRUSTED_HOSTS; do
    if [ -n "$trusted_host" ]; then
      set -- "$@" --trusted-host "$trusted_host"
    fi
  done
  IFS=$old_ifs
fi

exec "$@"
