-- Read-only hosted parity inventory: schemas, RLS, routines, grants and policies.
-- Each environment should produce the same normalized fingerprint.
WITH objects AS (
 SELECT n.nspname AS env, 'table' AS kind, c.relname AS name,
   jsonb_build_object('rls',c.relrowsecurity,'forced',c.relforcerowsecurity,
     'kind',c.relkind,'acl',c.relacl::text)::text AS definition
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname IN ('qa','prod') AND c.relkind IN ('r','p','v','m')
 UNION ALL
 SELECT table_schema,'column',table_name||'.'||column_name,
   jsonb_build_object('type',data_type,'nullable',is_nullable,'default',column_default,'ordinal',ordinal_position)::text
 FROM information_schema.columns WHERE table_schema IN ('qa','prod')
 UNION ALL
 SELECT n.nspname,'function',p.proname||'('||pg_get_function_identity_arguments(p.oid)||')',
   pg_get_functiondef(p.oid)||coalesce(p.proacl::text,'')
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN ('qa','prod') AND p.prokind='f'
 UNION ALL
 SELECT schemaname,'policy',tablename||'.'||policyname,
   jsonb_build_object('roles',roles,'command',cmd,'using',qual,'check',with_check,'permissive',permissive)::text
 FROM pg_policies WHERE schemaname IN ('qa','prod')
 UNION ALL
 SELECT schemaname,'index',indexname,indexdef FROM pg_indexes WHERE schemaname IN ('qa','prod')
 UNION ALL
 SELECT n.nspname,'constraint',c.relname||'.'||k.conname,pg_get_constraintdef(k.oid)
 FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname IN ('qa','prod')
), normalized AS (
 SELECT env,kind,regexp_replace(name,'\m(qa|prod)\M','environment','g') AS name,
 regexp_replace(definition,'\m(qa|prod)\M','environment','g') AS definition FROM objects
)
SELECT env,count(*) AS object_count,md5(string_agg(kind||':'||name||':'||definition,E'\n' ORDER BY kind,name)) AS fingerprint
FROM normalized GROUP BY env ORDER BY env;
