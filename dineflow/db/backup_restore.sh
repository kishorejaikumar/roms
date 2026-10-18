#!/usr/bin/env bash
# DineFlow backup and restore (durability and recovery).  Needs the PostgreSQL client tools (pg_dump, pg_restore, psql).
#   export DATABASE_URL=postgres://user:pass@host:5432/dineflow          # the live database
#   export RESTORE_URL=postgres://user:pass@host:5432/dineflow_restore   # an EMPTY database to restore into (create it first)
#   ./db/backup_restore.sh backup            -> backups/dineflow_YYYYMMDD_HHMMSS.dump  (compressed, custom format)
#   ./db/backup_restore.sh restore FILE      -> REPLACES schema dineflow in RESTORE_URL with FILE (never point RESTORE_URL at your live DB)
#   ./db/backup_restore.sh verify            -> compares row counts of DATABASE_URL and RESTORE_URL
#   ./db/backup_restore.sh demo              -> backup, restore, simulate a disaster, restore again, verify
# Supabase: use the DIRECT connection string for backup (pooler strings can break pg_dump). Supabase also keeps
# its own daily backups (Project -> Database -> Backups); this script is your own copy you can show in the viva.
set -euo pipefail
export PGOPTIONS='-c client_min_messages=warning'   # hide routine NOTICE/DETAIL chatter
cd "$(dirname "$0")/.."
TABLES="customers staff menu_items orders order_items payments reviews coupons table_reservations audit_log"
need() { [ -n "${!1:-}" ] || { echo "Set $1 first (see the top of this file)"; exit 1; }; }

counts() {  # $1 = connection url
  for t in $TABLES; do printf '%s=%s ' "$t" "$(psql "$1" -Atc "SELECT count(*) FROM dineflow.$t")"; done; echo
}
do_backup() {
  need DATABASE_URL; mkdir -p backups
  f="backups/dineflow_$(date +%Y%m%d_%H%M%S).dump"
  pg_dump "$DATABASE_URL" --schema=dineflow --format=custom --compress=6 --no-owner --file="$f"
  echo "Backup written: $f ($(du -h "$f" | cut -f1))" >&2
  echo "$f"
}
do_restore() {
  need RESTORE_URL; [ -f "${1:-}" ] || { echo "Backup file not found: ${1:-}"; exit 1; }
  # extensions and roles live outside the schema dump, so make sure they exist first
  psql "$RESTORE_URL" -q -v ON_ERROR_STOP=1 <<'SQL'
DROP SCHEMA IF EXISTS dineflow CASCADE;   -- the restore target is replaced completely (the dump re-creates the schema)
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS btree_gist;
DO $$ DECLARE r TEXT; BEGIN
  FOREACH r IN ARRAY ARRAY['df_anon','df_customer','df_kitchen','df_admin'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN EXECUTE format('CREATE ROLE %I NOLOGIN', r); END IF;
  END LOOP; END $$;
SQL
  pg_restore --dbname="$RESTORE_URL" --no-owner --exit-on-error "$1"
  echo "Restored $1 into RESTORE_URL"
}
do_verify() {
  need DATABASE_URL; need RESTORE_URL
  a="$(counts "$DATABASE_URL")"; b="$(counts "$RESTORE_URL")"
  echo "live    : $a"; echo "restored: $b"
  [ "$a" = "$b" ] && echo "VERIFY OK: every table has the same number of rows" || { echo "VERIFY FAILED: counts differ"; exit 2; }
}
case "${1:-}" in
  backup)  do_backup >/dev/null ;;
  restore) do_restore "${2:-}" ;;
  verify)  do_verify ;;
  demo)
    need DATABASE_URL; need RESTORE_URL
    f="$(do_backup)"; do_restore "$f"; do_verify
    echo "--- simulating a disaster on the restored copy: all orders deleted"
    psql "$RESTORE_URL" -q -c "TRUNCATE dineflow.orders CASCADE"
    echo "after disaster: $(counts "$RESTORE_URL")"
    do_restore "$f"; do_verify ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
