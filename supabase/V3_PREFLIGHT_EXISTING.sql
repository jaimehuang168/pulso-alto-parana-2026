-- 唯讀盤點。不更改任何資料。
SELECT to_regclass('public.profiles') AS profiles_table,to_regclass('public.responses') AS responses_table,to_regprocedure('public.submit_response_v2(jsonb)') IS NOT NULL AS v2_installed;
SELECT state,fieldwork_date,(SELECT count(*) FROM public.responses) AS legacy_responses FROM public.settings WHERE id=1;
SELECT role,active,count(*) FROM public.profiles GROUP BY role,active ORDER BY role,active;
SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='pulso_v3') AS v3_schema_exists;
