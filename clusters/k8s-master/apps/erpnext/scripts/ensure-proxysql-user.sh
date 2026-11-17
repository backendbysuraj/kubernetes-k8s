#!/usr/bin/env bash
# Usage: ensure-proxysql-user.sh <db_user> | --all
# Makes ProxySQL's mysql_users match the tenant users on Galera. Idempotent.
set -Eeuo pipefail

TARGET="${1:---all}"

GALERA_HOST="${GALERA_HOST:?GALERA_HOST is not set}"
GALERA_PORT="${GALERA_PORT:-3306}"
SYNC_USER="${SYNC_USER:?SYNC_USER is not set}"
SYNC_PW="${SYNC_PW:?SYNC_PW is not set}"
PX_HOST="${PX_HOST:?PX_HOST is not set}"
PX_ADMIN_PORT="${PX_ADMIN_PORT:-6032}"
PX_ADMIN_USER="${PX_ADMIN_USER:-radmin}"
PX_ADMIN_PW="${PX_ADMIN_PW:?PX_ADMIN_PW is not set}"
HOSTGROUP="${HOSTGROUP:-101}"
RETRIES="${RETRIES:-10}"
RETRY_SLEEP="${RETRY_SLEEP:-1}"
LOCK_FILE="${LOCK_FILE:-/tmp/proxysql-user-sync.lock}"

MYSQL_BIN="$(command -v mariadb || command -v mysql || true)"
[[ -n "$MYSQL_BIN" ]] || { echo "[user-sync] no mariadb/mysql client in image" >&2; exit 127; }

log() { echo "$(date -u +%FT%TZ) [user-sync] $*" >&2; }

galera() { MYSQL_PWD="$SYNC_PW"     "$MYSQL_BIN" -h"$GALERA_HOST" -P"$GALERA_PORT"    -u"$SYNC_USER"     -N -B --connect-timeout=5 "$@"; }
admin()  { MYSQL_PWD="$PX_ADMIN_PW" "$MYSQL_BIN" -h"$PX_HOST"     -P"$PX_ADMIN_PORT" -u"$PX_ADMIN_USER" -N -B --connect-timeout=5 "$@"; }

if [[ "$TARGET" == "--all" ]]; then
  G_WHERE="LEFT(User,1)='_'"
  P_WHERE="substr(username,1,1)='_'"     # ProxySQL admin is SQLite: no default LIKE escape
else
  [[ "$TARGET" =~ ^[A-Za-z0-9_]{1,64}$ ]] || { log "invalid user name"; exit 64; }
  G_WHERE="User='$TARGET'"
  P_WHERE="username='$TARGET'"
fi

# serialize concurrent runs
exec 9>"$LOCK_FILE"
flock -w 60 9 || { log "could not get lock"; exit 75; }

fetch_desired() {
  # wsrep_sync_wait=1: wait until this node has applied pending cluster writes
  galera -e "SET SESSION wsrep_sync_wait=1;
             SELECT DISTINCT User, Password FROM mysql.user
             WHERE $G_WHERE AND Password <> '';" | LC_ALL=C sort
}
fetch_current() {
  admin -e "SELECT DISTINCT username, password FROM runtime_mysql_users WHERE $P_WHERE;" | LC_ALL=C sort
}

desired=""
for ((i=1; i<=RETRIES; i++)); do
  if desired="$(fetch_desired 2>/dev/null)" && [[ -n "$desired" ]]; then break; fi
  desired=""; sleep "$RETRY_SLEEP"
done

if [[ -z "$desired" ]]; then
  [[ "$TARGET" == "--all" ]] && exit 0
  log "user '$TARGET' not found on Galera after $RETRIES attempts"; exit 2
fi

current="$(fetch_current)" || { log "cannot read ProxySQL admin at $PX_HOST:$PX_ADMIN_PORT"; exit 3; }
[[ "$desired" == "$current" ]] && exit 0

sql=""
while IFS=$'\t' read -r u h; do
  if [[ "$u" =~ ^[A-Za-z0-9_]+$ && "$h" =~ ^\*[0-9A-Fa-f]{40}$ ]]; then
    sql+="REPLACE INTO mysql_users(username,password,default_hostgroup,active) VALUES ('$u','$h',$HOSTGROUP,1);"
  else
    log "skipping unexpected row for user '$u'"
  fi
done <<< "$desired"

admin -e "${sql}LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;" \
  || { log "failed applying users to ProxySQL"; exit 4; }

[[ "$(fetch_current)" == "$desired" ]] || { log "runtime mismatch after load"; exit 5; }
log "synced $(grep -c . <<< "$desired") user(s) (target: $TARGET)"
