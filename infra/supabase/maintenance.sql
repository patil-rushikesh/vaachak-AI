-- Run as the deployment administrator after enabling pg_cron in Supabase.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('vaachak-dev-maintenance','*/10 * * * *',
 $$SELECT dev.ensure_month((current_date+interval '1 month')::date); SELECT dev.build_insights(); SELECT dev.refresh_class_snapshots();$$);
SELECT cron.schedule('vaachak-qa-maintenance','*/10 * * * *',
 $$SELECT qa.ensure_month((current_date+interval '1 month')::date); SELECT qa.build_insights(); SELECT qa.refresh_class_snapshots();$$);
SELECT cron.schedule('vaachak-prod-maintenance','*/10 * * * *',
 $$SELECT prod.ensure_month((current_date+interval '1 month')::date); SELECT prod.build_insights(); SELECT prod.refresh_class_snapshots();$$);
