-- Pulso：修正「UPDATE requires a WHERE clause」。
-- 在已完成 v2 安裝的同一個 Supabase 專案，使用 SQL Editor 執行整份。
-- 不需修改任何文字；不填密碼、信箱或金鑰。
-- 只修正下列四個既有函式中的通知更新；不直接停用帳號，不更動問卷或日期。
-- 保留既有函式的管理者檢查、權限、擁有者與 security definer 設定。
-- 不關閉 RLS 或 safeupdate；未知版本會停止，整個修正會回滾。
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $patch$
DECLARE
  signature text;
  routine regprocedure;
  definition text;
  old_update constant text := 'update public.district_signals set version=version+1,changed_at=clock_timestamp();';
  new_update constant text := 'update public.district_signals set version=version+1,changed_at=clock_timestamp() where district_id in (select id from public.districts);';
  matches integer;
BEGIN
  IF to_regprocedure('public.submit_response_v2(jsonb)') IS NULL THEN
    RAISE EXCEPTION '缺少 Pulso v2 收件函式。已停止，請先核對專案及安裝版本。';
  END IF;

  FOREACH signature IN ARRAY ARRAY[
    'public.set_account_active(uuid,boolean)',
    'public.set_viewer_access(boolean)',
    'public.save_settings(jsonb)',
    'public.set_fieldwork_state(text)'
  ] LOOP
    routine := to_regprocedure(signature);
    IF routine IS NULL THEN
      RAISE EXCEPTION '找不到必要函式：%。未完成任何修正。', signature;
    END IF;
    definition := pg_get_functiondef(routine);
    matches := (length(definition) - length(replace(definition, old_update, ''))) / length(old_update);
    IF matches = 1 AND position(new_update IN definition) = 0 THEN
      EXECUTE replace(definition, old_update, new_update);
    ELSIF matches = 0 AND position(new_update IN definition) > 0 THEN
      -- 已修正，保留設定；允許安全地重複執行。
      NULL;
    ELSE
      RAISE EXCEPTION '函式 % 不是已核對的版本，已停止並回滾，沒有覆蓋。', signature;
    END IF;
  END LOOP;
END;
$patch$;
COMMIT;

-- 應看到四列，patch_status 都是 OK。這只驗證函式定義；仍需回 App 重試停用。
SELECT
  signature AS function_name,
  CASE WHEN
    position(
      'where district_id in (select id from public.districts);'
      IN pg_get_functiondef(to_regprocedure(signature))
    ) > 0
    AND position(
      'update public.district_signals set version=version+1,changed_at=clock_timestamp();'
      IN pg_get_functiondef(to_regprocedure(signature))
    ) = 0
  THEN 'OK' ELSE 'CHECK_REQUIRED' END AS patch_status
FROM (VALUES
  ('public.set_account_active(uuid,boolean)'),
  ('public.set_viewer_access(boolean)'),
  ('public.save_settings(jsonb)'),
  ('public.set_fieldwork_state(text)')
) AS expected(signature);
