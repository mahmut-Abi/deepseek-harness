#!/bin/sh
set -eu

DSH_HOME=${DSH_HOME:-/root/.dsh}
DSH_PORT=${DSH_PORT:-3080}
DSH_PUBLIC_HOST=${DSH_PUBLIC_HOST:-}
DSH_TRUSTED_HOSTS=${DSH_TRUSTED_HOSTS:-}
PNPM_STORE_DIR=${PNPM_STORE_DIR:-$DSH_HOME/.pnpm-store}
AUTH_GATE_PLUGIN_SPEC=${AUTH_GATE_PLUGIN_SPEC:-https://codeload.github.com/TecFancy/dsh-auth-gate/tar.gz/0bd0592a46ee93019d0765be7fe6f6efceb9d377}
AUTH_GATE_ALLOW_BUILD_KEY=${AUTH_GATE_ALLOW_BUILD_KEY:-dsh-auth-gate@$AUTH_GATE_PLUGIN_SPEC}
DSH_AUTH_PATCH=${DSH_AUTH_PATCH:-$DSH_HOME/docker-auth-gate.patch.yml}
DSH_AUTH_COOKIE_SECURE=${DSH_AUTH_COOKIE_SECURE:-true}
DSH_AUTH_USERNAME=${DSH_AUTH_USERNAME:-admin}
DSH_AUTH_USERS_FILE=${DSH_AUTH_USERS_FILE:-}
SEED_HOME=/opt/dsh-home-seed
PROFILE_DIR="$DSH_HOME/profiles/web"

ensure_profile_store_dir() {
  if [ -f "$PROFILE_DIR/pnpm-workspace.yaml" ]; then
    if grep -q '^storeDir:' "$PROFILE_DIR/pnpm-workspace.yaml"; then
      sed -i "s|^storeDir:.*|storeDir: $PNPM_STORE_DIR|" "$PROFILE_DIR/pnpm-workspace.yaml"
    else
      printf '\nstoreDir: %s\n' "$PNPM_STORE_DIR" >> "$PROFILE_DIR/pnpm-workspace.yaml"
    fi
  fi
}

ensure_auth_gate_allow_build() {
  if [ -f "$PROFILE_DIR/pnpm-workspace.yaml" ]; then
    if ! grep -q '^allowBuilds:' "$PROFILE_DIR/pnpm-workspace.yaml"; then
      printf '\nallowBuilds:\n' >> "$PROFILE_DIR/pnpm-workspace.yaml"
    fi
    if ! grep -Fq "  $AUTH_GATE_ALLOW_BUILD_KEY: true" "$PROFILE_DIR/pnpm-workspace.yaml"; then
      printf '  %s: true\n' "$AUTH_GATE_ALLOW_BUILD_KEY" >> "$PROFILE_DIR/pnpm-workspace.yaml"
    fi
  fi
}

profile_has_auth_gate() {
  node -e 'const manifest = require(process.argv[1]); process.exit(manifest.dependencies?.["dsh-auth-gate"] ? 0 : 1)' "$PROFILE_DIR/package.json"
}

write_auth_patch() {
  AUTH_MODE="$1" DSH_AUTH_PATCH="$DSH_AUTH_PATCH" DSH_AUTH_COOKIE_SECURE="$DSH_AUTH_COOKIE_SECURE" DSH_AUTH_USERS_FILE="$DSH_AUTH_USERS_FILE" node <<'NODE'
const fs = require('node:fs')

const mode = process.env.AUTH_MODE
const patchPath = process.env.DSH_AUTH_PATCH
const cookieSecure = (process.env.DSH_AUTH_COOKIE_SECURE ?? 'true').toLowerCase() !== 'false'
const usersFile = process.env.DSH_AUTH_USERS_FILE ?? ''

let text = `- id: dsh-auth-gate
  config:
    mode: ${JSON.stringify(mode)}
    cookieSecure: ${cookieSecure}
`
if (mode === 'password' && usersFile !== '') {
  text += `    usersFile: ${JSON.stringify(usersFile)}
`
}
if (mode === 'token') {
  text += '    tokenRef: "DSH_AUTH_TOKEN"\n'
}

fs.writeFileSync(patchPath, text, { mode: 0o600 })
NODE
}

upsert_auth_user() {
  (
    cd "$PROFILE_DIR"
    DSH_AUTH_PASSWORD_VALUE="$DSH_AUTH_PASSWORD" DSH_AUTH_USERNAME="$DSH_AUTH_USERNAME" DSH_AUTH_USERS_FILE="$DSH_AUTH_USERS_FILE" node --input-type=module <<'NODE'
import { join } from 'node:path'
import { hashPassword } from './node_modules/dsh-auth-gate/lib/password.js'
import { loadUsersFile, USERNAME_RE, writeUsersFile } from './node_modules/dsh-auth-gate/lib/users-file.js'

const username = process.env.DSH_AUTH_USERNAME ?? 'admin'
const password = process.env.DSH_AUTH_PASSWORD_VALUE ?? ''
const usersFile = process.env.DSH_AUTH_USERS_FILE || join(process.env.DSH_HOME ?? '/root/.dsh', 'auth', 'users.yaml')

if (!USERNAME_RE.test(username)) {
  throw new Error(`invalid DSH_AUTH_USERNAME: ${username}`)
}
if (password === '') {
  throw new Error('DSH_AUTH_PASSWORD must not be empty')
}

const { snapshot } = await loadUsersFile(usersFile)
snapshot.users.set(username, { passwordHash: await hashPassword(password), disabled: false })
await writeUsersFile(usersFile, snapshot)
NODE
  )
}

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

ensure_profile_store_dir
ensure_auth_gate_allow_build

if [ -f "$PROFILE_DIR/node_modules/.modules.yaml" ]; then
  DESIRED_STORE_PATH=$(cd "$PROFILE_DIR" && pnpm store path)
  if ! grep -Fq "\"storeDir\": \"$DESIRED_STORE_PATH\"" "$PROFILE_DIR/node_modules/.modules.yaml"; then
    rm -rf "$PROFILE_DIR/node_modules"
    (cd "$PROFILE_DIR" && pnpm install)
  fi
fi

if [ -f "$PROFILE_DIR/package.json" ] && ! profile_has_auth_gate; then
  dsh plugin --profile web add --store-dir "$PNPM_STORE_DIR" "$AUTH_GATE_PLUGIN_SPEC"
fi
if [ -f "$PROFILE_DIR/package.json" ] && profile_has_auth_gate && [ ! -f "$PROFILE_DIR/node_modules/dsh-auth-gate/package.json" ]; then
  (cd "$PROFILE_DIR" && pnpm install)
fi

if [ -n "${DSH_AUTH_PASSWORD:-}" ]; then
  write_auth_patch password
  upsert_auth_user
  unset DSH_AUTH_PASSWORD
elif [ -n "${DSH_AUTH_TOKEN:-}" ]; then
  write_auth_patch token
else
  echo 'dsh-auth-gate: set DSH_AUTH_PASSWORD or DSH_AUTH_TOKEN; without either, the default token gate denies access' >&2
  if [ -f "$DSH_AUTH_PATCH" ]; then
    rm -f "$DSH_AUTH_PATCH"
  fi
fi

rm -f "$DSH_HOME/task-board/ledger-v2.lock"

LAN_IP=${LAN_IP:-}
if [ -z "$LAN_IP" ] && command -v ip >/dev/null 2>&1; then
  LAN_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')
fi
if [ -z "$LAN_IP" ] && command -v hostname >/dev/null 2>&1; then
  LAN_IP=$(hostname -I 2>/dev/null | awk '{ print $1 }')
fi

export DSH_HOME DSH_PORT LAN_IP DSH_PUBLIC_HOST DSH_TRUSTED_HOSTS PNPM_STORE_DIR DSH_AUTH_PATCH
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/dsh.conf
