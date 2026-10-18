#!/usr/bin/env bash
# Loads every SQL file in order. Usage:  DATABASE_URL=postgres://... ./db/load_all.sh
set -euo pipefail
: "${DATABASE_URL:?Set DATABASE_URL first}"
cd "$(dirname "$0")"
for f in 01_schema_er 02_normalization 03_sql_programming 04_transactions 04b_demo 05_optimization 05b_benchmark 06_seed_data 07_tests 08_security; do
  echo "== $f"; psql "$DATABASE_URL" -q -v ON_ERROR_STOP=1 -f "$f.sql" > "/tmp/dineflow_$f.log"
done
psql "$DATABASE_URL" -c "SET search_path = dineflow, public; SELECT count(*) FILTER (WHERE passed) || ' of ' || count(*) AS database_checks FROM fn_run_tests(); SELECT count(*) FILTER (WHERE passed) || ' of ' || count(*) AS security_checks FROM fn_run_security_tests();"
