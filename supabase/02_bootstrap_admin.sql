-- AFTER creating the coordinator user in Supabase Authentication > Users.
-- Replace the email below with that account's actual email. Run as SQL owner.
-- Never add an automatic trigger that assigns admin to every signed-up user.
do $$
declare admin_email text:='REPLACE_WITH_COORDINATOR_EMAIL'; uid uuid;
begin
  if admin_email='REPLACE_WITH_COORDINATOR_EMAIL' then raise exception 'Primero reemplace el correo de coordinación.'; end if;
  select id into uid from auth.users where lower(email)=lower(admin_email);
  if uid is null then raise exception 'Cree primero este usuario en Authentication > Users.'; end if;
  if exists(select 1 from public.profiles where id=uid) then raise exception 'Ese usuario ya tiene un perfil; no se cambia de rol automáticamente.'; end if;
  insert into public.profiles(id,code,role,active) values(uid,'COORD-01','admin',true);
  insert into public.audit_log(actor_id,action) values(uid,'coordinator_bootstrapped');
end$$;
