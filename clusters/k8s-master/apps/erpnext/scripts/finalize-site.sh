#!/usr/bin/env bash
# Usage: finalize-site.sh <site>
# Register the site's DB user in ProxySQL, verify a real login through ProxySQL, then cut the site over.
set -uo pipefail

SITE="${1:?usage: $0 <site>}"
cd /home/frappe/frappe-bench
CFG="sites/${SITE}/site_config.json"
DIR="$(dirname "$0")"

export PX_HOST="${PX_HOST:-$DB_HOST}"       # ProxySQL service (from the Job's DB_HOST)
PX_PORT="${PX_PORT:-$DB_PORT}"              # 6033
MYSQL_BIN="$(command -v mariadb || command -v mysql || true)"
[[ -n "$MYSQL_BIN" ]] || { echo "[finalize] no mariadb/mysql client in image" >&2; exit 127; }

[[ -f "$CFG" ]] || { echo "[finalize] $CFG not found" >&2; exit 1; }
DB_USER="$(jq -r '.db_user // .db_name' "$CFG")"
DB_PW="$(jq -r '.db_password' "$CFG")"

if ! bash "$DIR/ensure-proxysql-user.sh" "$DB_USER"; then
  echo "[finalize] WARN: could not register $DB_USER in ProxySQL; $SITE stays on direct Galera" >&2
  exit 10
fi

ok=0
for _ in $(seq 1 10); do
  if MYSQL_PWD="$DB_PW" "$MYSQL_BIN" -h"$PX_HOST" -P"$PX_PORT" -u"$DB_USER" "$DB_USER" \
       --connect-timeout=5 -e 'SELECT 1' >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
if [[ $ok -ne 1 ]]; then
  echo "[finalize] WARN: login via ProxySQL failed for $DB_USER; $SITE stays on direct Galera" >&2
  exit 11
fi

tmp="${CFG}.tmp.$$"
jq --arg h "$PX_HOST" --argjson p "$PX_PORT" '.db_host=$h | .db_port=$p' "$CFG" > "$tmp" && mv "$tmp" "$CFG"
echo "[finalize] OK: $SITE routed through ${PX_HOST}:${PX_PORT}"
