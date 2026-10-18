-- =====================================================================
-- DineFlow | setup checker.  Run it on the database your website uses:
--   psql "$DATABASE_URL" -f db/check_setup.sql        (or paste it into the Supabase SQL editor)
-- Every row must show  ok = true.  A false row names the file you still have to run.
-- Run it as the SAME user that your DATABASE_URL uses.
-- =====================================================================
SET search_path = dineflow, public, extensions;
SELECT item, ok, CASE WHEN ok THEN '' ELSE fix END AS "if false: run or re-run" FROM (VALUES
 ('schema dineflow exists',                                   to_regnamespace('dineflow') IS NOT NULL, '01_schema_er.sql'),
 ('table table_reservations exists',                          to_regclass('dineflow.table_reservations') IS NOT NULL, '01_schema_er.sql'),
 ('exclusion constraint ex_no_double_booking',                EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ex_no_double_booking'), '01_schema_er.sql'),
 ('function fn_available_tables (Reserve page)',              to_regprocedure('dineflow.fn_available_tables(timestamptz,timestamptz,integer)') IS NOT NULL, '03_sql_programming.sql'),
 ('function fn_reserve_table (Reserve page)',                 to_regprocedure('dineflow.fn_reserve_table(integer,integer,integer,timestamptz,integer)') IS NOT NULL, '03_sql_programming.sql'),
 ('view v_floor_map (Floor map page)',                        to_regclass('dineflow.v_floor_map') IS NOT NULL, '03_sql_programming.sql (the newest version, section 2.14)'),
 ('function fn_free_tables (Menu page)',                      to_regprocedure('dineflow.fn_free_tables()') IS NOT NULL, '08_security.sql'),
 ('4 database roles exist (df_anon, df_customer, df_kitchen, df_admin)', (SELECT COUNT(*) FROM pg_roles WHERE rolname IN ('df_anon','df_customer','df_kitchen','df_admin')) = 4, '08_security.sql'),
 ('this user may switch to df_admin / df_customer',           CASE WHEN to_regrole('df_admin') IS NULL OR to_regrole('df_customer') IS NULL THEN false
                                                                   ELSE pg_has_role(current_user, 'df_admin', 'MEMBER') AND pg_has_role(current_user, 'df_customer', 'MEMBER') END, '08_security.sql, run by the SAME user as DATABASE_URL (or set USE_DB_ROLES=off)'),
 ('df_admin and df_kitchen can read v_floor_map',             CASE WHEN to_regrole('df_admin') IS NULL OR to_regclass('dineflow.v_floor_map') IS NULL THEN false
                                                                   ELSE has_table_privilege('df_admin','dineflow.v_floor_map','SELECT') AND has_table_privilege('df_kitchen','dineflow.v_floor_map','SELECT') END, '08_security.sql (run it AFTER 03)'),
 ('df_customer can run fn_reserve_table',                     CASE WHEN to_regrole('df_customer') IS NULL OR to_regprocedure('dineflow.fn_reserve_table(integer,integer,integer,timestamptz,integer)') IS NULL THEN false
                                                                   ELSE has_function_privilege('df_customer','dineflow.fn_reserve_table(integer,integer,integer,timestamptz,integer)','EXECUTE') END, '08_security.sql (run it AFTER 03)'),
 ('df_anon can run fn_available_tables',                      CASE WHEN to_regrole('df_anon') IS NULL OR to_regprocedure('dineflow.fn_available_tables(timestamptz,timestamptz,integer)') IS NULL THEN false
                                                                   ELSE has_function_privilege('df_anon','dineflow.fn_available_tables(timestamptz,timestamptz,integer)','EXECUTE') END, '08_security.sql (run it AFTER 03)'),
 ('df_customer can read table_reservations',                  CASE WHEN to_regrole('df_customer') IS NULL OR to_regclass('dineflow.table_reservations') IS NULL THEN false
                                                                   ELSE has_table_privilege('df_customer','dineflow.table_reservations','SELECT') END, '08_security.sql'),
 ('routines are SECURITY DEFINER (08 applied after 03/04)',   (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'dineflow' AND p.proname !~ '^fn_run_' AND NOT p.prosecdef) = 0, '08_security.sql again (run it after any re-run of 03 or 04)'),
 ('dining tables exist (seed data loaded)',                   CASE WHEN to_regclass('dineflow.restaurant_tables') IS NULL THEN false ELSE (SELECT COUNT(*) FROM restaurant_tables) > 0 END, '06_seed_data.sql')
) v(item, ok, fix);
