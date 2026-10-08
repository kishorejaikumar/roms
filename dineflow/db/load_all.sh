#!/usr/bin/env bash
# Loads every SQL file in order. Usage:  DATABASE_URL=postgres://... ./db/load_all.sh
set -euo pipefail
: "${DATABASE_URL:?Set DATABASE_URL first}"
cd "$(dirname "$0")"
for f in 01_schema_er 02_normalization 03_sql_programming 04_transactions 05_optimization 06_seed_data 07_tests; do
  echo "== $f"; psql "$DATABASE_URL" -q -v ON_ERROR_STOP=1 -f "$f.sql" > "/tmp/dineflow_$f.log"
done
psql "$DATABASE_URL" -c "SET search_path = dineflow, public; SELECT count(*) FILTER (WHERE passed) || ' of ' || count(*) AS checks_passed FROM fn_run_tests();"
