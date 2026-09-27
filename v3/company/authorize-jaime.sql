-- Application owner: explicit user request. No password or Auth user is created or changed.
DO $$
DECLARE u uuid; matches integer;
BEGIN
 SELECT count(*),(array_agg(id))[1] INTO matches,u FROM auth.users
 WHERE lower(email)='jaimehuang168@gmail.com' AND email_confirmed_at IS NOT NULL;
 IF matches<>1 OR NOT EXISTS(SELECT 1 FROM pulso_v3.actors WHERE user_id=u AND role='admin' AND active AND enrolled AND person_id IS NULL)
 THEN RAISE EXCEPTION 'V3_JAIME_VERIFIED_ADMIN_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pulso_v3.super_admins WHERE user_id=u) THEN
  INSERT INTO pulso_v3.super_admins(user_id,authorization_reference)
    VALUES(u,'Owner explicitly designated by jaimehuang168: V3.1 company administration request');
  PERFORM pulso_v3.log(u,'governance.super_admin_designated',u,NULL,jsonb_build_object('basis','Explicit owner request; not a backup or acceptance attestation'));
 END IF;
END $$;
