-- PULSO v1.0.0 — Install in a NEW, dedicated Supabase project.
-- Run as the SQL Editor database owner. Never in a browser.
-- One election / one contest per project. No voter identifiers are collected.
begin;
create schema if not exists app_private;
revoke all on schema app_private from public, anon;
grant usage on schema app_private to authenticated, service_role;

create table public.districts (
  id text primary key check (id in ('cde','minga','hernandarias','franco')),
  code text not null unique, name text not null,
  sort_order integer not null, target_agents integer not null default 15 check(target_agents=15)
);
insert into public.districts(id,code,name,sort_order) values
 ('cde','CDE','Ciudad del Este',1),('minga','MGA','Minga Guazú',2),
 ('hernandarias','HER','Hernandarias',3),('franco','PFR','Presidente Franco',4);

create table public.settings (
  id smallint primary key default 1 check(id=1),
  title text not null default 'Operativo por configurar' check(char_length(title) between 1 and 120),
  contest text not null default 'Cargo por confirmar' check(char_length(contest) between 1 and 120),
  fieldwork_date date,
  state text not null default 'setup' check(state in ('setup','open','closed')),
  sample_interval integer not null default 5 check(sample_interval between 1 and 100),
  goal_per_district integer not null default 1000 check(goal_per_district between 1 and 100000),
  methodology text not null default '' check(char_length(methodology)<=4000),
  catalog_confirmed boolean not null default false,
  opened_at timestamptz, closed_at timestamptz,
  updated_at timestamptz not null default now(),
  check((state='setup' and opened_at is null and closed_at is null) or
        (state='open' and opened_at is not null and closed_at is null) or
        (state='closed' and opened_at is not null and closed_at is not null and closed_at>=opened_at))
);
insert into public.settings(id) values(1);
create table public.candidates (
  id uuid primary key default gen_random_uuid(),
  district_id text not null references public.districts(id),
  name text not null check(char_length(name) between 1 and 100),
  list_label text not null default '' check(char_length(list_label)<=100),
  sort_order integer not null default 0,
  active boolean not null default true, is_template boolean not null default true,
  unique(id,district_id)
);
create unique index candidates_active_name on public.candidates(district_id,lower(name)) where active;
create table public.stations (
  id uuid primary key default gen_random_uuid(),
  district_id text not null references public.districts(id),
  name text not null check(char_length(name) between 1 and 160),
  active boolean not null default true, is_template boolean not null default true,
  unique(id,district_id)
);
create unique index stations_active_name on public.stations(district_id,lower(name)) where active;
create table public.profiles (
  id uuid primary key references auth.users(id) on delete restrict,
  code text not null unique check(char_length(code) between 3 and 40),
  role text not null check(role in ('admin','supervisor','interviewer')),
  district_id text references public.districts(id),
  station_id uuid, slot integer,
  active boolean not null default true,
  last_seen timestamptz,
  created_at timestamptz not null default now(),
  foreign key(station_id,district_id) references public.stations(id,district_id),
  unique(district_id,slot),
  check((role='admin' and district_id is null and station_id is null and slot is null) or
        (role='supervisor' and district_id is not null and station_id is null and slot is null) or
        (role='interviewer' and district_id is not null and station_id is not null and slot is not null and slot between 1 and 15))
);
create table public.responses (
  id uuid primary key,
  agent_id uuid not null references public.profiles(id),
  district_id text not null references public.districts(id),
  station_id uuid not null,
  outcome text not null check(outcome in ('candidate','blank','invalid','undisclosed','refused')),
  candidate_id uuid,
  consent boolean not null,
  already_voted boolean not null check(already_voted),
  captured_at timestamptz not null, -- device-declared time, not independently verified
  received_at timestamptz not null default clock_timestamp(), -- authoritative receipt time
  voided_at timestamptz, voided_by uuid references public.profiles(id),
  void_reason text check(void_reason in ('capture_error','quality_control')),
  foreign key(station_id,district_id) references public.stations(id,district_id),
  foreign key(candidate_id,district_id) references public.candidates(id,district_id),
  check((outcome='candidate' and candidate_id is not null) or (outcome<>'candidate' and candidate_id is null)),
  check((outcome='refused' and consent=false) or (outcome<>'refused' and consent=true)),
  check((voided_at is null and voided_by is null and void_reason is null) or
        (voided_at is not null and voided_by is not null and void_reason is not null))
);
create index responses_district_receipt on public.responses(district_id,received_at) where voided_at is null;
create index responses_agent_receipt on public.responses(agent_id,received_at desc);
create index responses_candidate on public.responses(candidate_id) where voided_at is null;
create index responses_station on public.responses(station_id) where voided_at is null;
create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id),
  action text not null check(char_length(action)<=80),
  subject_id uuid,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp()
);
create table public.district_signals (
  district_id text primary key references public.districts(id),
  version bigint not null default 0,
  changed_at timestamptz not null default now()
);
insert into public.district_signals(district_id) select id from public.districts;
insert into public.candidates(district_id,name,list_label,sort_order)
 select d.id,'Candidatura '||c.letter,'Lista de ejemplo '||c.letter,c.ord
 from public.districts d cross join (values('A',0),('B',1),('C',2)) c(letter,ord);
insert into public.stations(district_id,name)
 select d.id,'Local de ejemplo '||lpad(n::text,2,'0') from public.districts d cross join generate_series(1,3) n;

-- Helpers return server-owned profile data, never user-editable Auth metadata.
create function app_private.active_profile() returns public.profiles
language sql stable security definer set search_path=''
as $$select p.* from public.profiles p where p.id=auth.uid() and p.active$$;
create function app_private.is_admin() returns boolean
language sql stable security definer set search_path=''
as $$select exists(select 1 from public.profiles p where p.id=auth.uid() and p.active and p.role='admin')$$;
create function app_private.has_access_to(d text) returns boolean
language sql stable security definer set search_path=''
as $$select exists(select 1 from public.profiles p where p.id=auth.uid() and p.active and (p.role='admin' or p.district_id=d))$$;
create function app_private.profile_guard() returns trigger
language plpgsql security definer set search_path=''
as $$declare dc text; begin
 if new.role='interviewer' then
   select code into dc from public.districts where id=new.district_id;
   if new.code<>dc||'-'||lpad(new.slot::text,2,'0') then raise exception 'Código no corresponde al distrito y puesto.' using errcode='23514'; end if;
   if not exists(select 1 from public.stations s where s.id=new.station_id and s.district_id=new.district_id and s.active) then raise exception 'Local inválido para el distrito.' using errcode='23514'; end if;
 end if;
 if tg_op='UPDATE' and (new.district_id is distinct from old.district_id or new.station_id is distinct from old.station_id or new.slot is distinct from old.slot or new.role is distinct from old.role or new.code is distinct from old.code)
   and exists(select 1 from public.settings where state<>'setup') then raise exception 'Las asignaciones están bloqueadas después de la apertura.' using errcode='23514'; end if;
 return new; end$$;
create trigger profiles_guard before insert or update on public.profiles for each row execute function app_private.profile_guard();
create function app_private.signal_change() returns trigger
language plpgsql security definer set search_path=''
as $$begin
 update public.district_signals set version=version+1,changed_at=clock_timestamp() where district_id=new.district_id;
 return new; end$$;
create trigger responses_signal after insert or update on public.responses for each row execute function app_private.signal_change();

-- No anonymous data access; no direct authenticated writes.
alter table public.districts enable row level security;
alter table public.settings enable row level security;
alter table public.candidates enable row level security;
alter table public.stations enable row level security;
alter table public.profiles enable row level security;
alter table public.responses enable row level security;
alter table public.audit_log enable row level security;
alter table public.district_signals enable row level security;
revoke all on table public.districts,public.settings,public.candidates,public.stations,public.profiles,public.responses,public.audit_log,public.district_signals from public,anon,authenticated;
grant select on table public.districts,public.settings,public.candidates,public.stations,public.profiles,public.responses,public.audit_log,public.district_signals to authenticated;
grant all on table public.districts,public.settings,public.candidates,public.stations,public.profiles,public.responses,public.audit_log,public.district_signals to service_role;
grant usage,select on sequence public.audit_log_id_seq to service_role;
create policy districts_read on public.districts for select to authenticated using(app_private.has_access_to(id));
create policy settings_read on public.settings for select to authenticated using((app_private.active_profile()).id is not null);
create policy candidates_read on public.candidates for select to authenticated using(active and app_private.has_access_to(district_id));
create policy stations_read on public.stations for select to authenticated using(active and app_private.has_access_to(district_id));
create policy profiles_read on public.profiles for select to authenticated using(
 (app_private.active_profile()).id is not null and (id=auth.uid() or app_private.is_admin() or ((app_private.active_profile()).role='supervisor' and district_id=(app_private.active_profile()).district_id)));
create policy responses_own_read on public.responses for select to authenticated using(agent_id=auth.uid() and (app_private.active_profile()).role='interviewer');
create policy audit_admin_read on public.audit_log for select to authenticated using(app_private.is_admin());
create policy signals_read on public.district_signals for select to authenticated using(app_private.has_access_to(district_id));

create function public.bootstrap() returns jsonb
language plpgsql stable security definer set search_path=''
as $$declare p public.profiles; begin
 p:=app_private.active_profile(); if p.id is null then raise exception 'Cuenta no habilitada o sin perfil asignado.' using errcode='42501'; end if;
 return jsonb_build_object('profile',to_jsonb(p),'settings',(select to_jsonb(s) from public.settings s where id=1),
 'districts',(select coalesce(jsonb_agg(to_jsonb(d) order by d.sort_order),'[]'::jsonb) from public.districts d where p.role='admin' or d.id=p.district_id),
 'candidates',(select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order),'[]'::jsonb) from public.candidates c where c.active and (p.role='admin' or c.district_id=p.district_id)),
 'stations',(select coalesce(jsonb_agg(to_jsonb(s) order by s.name),'[]'::jsonb) from public.stations s where s.active and (p.role='admin' or s.district_id=p.district_id)));
 end$$;
create function public.ping() returns timestamptz
language plpgsql security definer set search_path=''
as $$declare t timestamptz:=clock_timestamp(); begin
 update public.profiles set last_seen=t where id=auth.uid() and active;
 if not found then raise exception 'Cuenta no habilitada.' using errcode='42501'; end if;
 return t; end$$;

create function public.submit_response(p_id uuid,p_station_id uuid,p_outcome text,p_candidate_id uuid,p_captured_at timestamptz,p_consent boolean,p_already_voted boolean)
returns uuid language plpgsql security definer set search_path=''
as $$declare p public.profiles; s public.settings; oldrow public.responses; new_id uuid; begin
 select * into p from public.profiles where id=auth.uid() and active;
 if p.id is null or p.role<>'interviewer' then raise exception 'Se requiere un encuestador habilitado.' using errcode='42501'; end if;
 -- Retry acknowledgment remains possible after closure. A changed payload is NOT idempotent.
 select * into oldrow from public.responses where id=p_id;
 if found then
   if oldrow.agent_id<>p.id or oldrow.station_id is distinct from p_station_id or oldrow.outcome is distinct from p_outcome or oldrow.candidate_id is distinct from p_candidate_id or oldrow.captured_at is distinct from p_captured_at or oldrow.consent is distinct from p_consent or oldrow.already_voted is distinct from p_already_voted then raise exception 'Identificador repetido con contenido distinto.' using errcode='23514'; end if;
   return oldrow.id;
 end if;
 select * into s from public.settings where id=1 for share;
 -- Lock order is settings -> profile. Serialize one agent, not all 60 agents.
 select * into p from public.profiles where id=auth.uid() and active for update;
 if p.id is null or p.role<>'interviewer' then raise exception 'Se requiere un encuestador habilitado.' using errcode='42501'; end if;
 if s.state='setup' or s.opened_at is null then raise exception 'La jornada no está abierta.' using errcode='P0001'; end if;
 if p_station_id is distinct from p.station_id then raise exception 'El local no coincide con su asignación.' using errcode='23514'; end if;
 if p_captured_at is null or p_captured_at<s.opened_at or p_captured_at>clock_timestamp()+interval '5 minutes' or (p_captured_at at time zone 'America/Asuncion')::date is distinct from s.fieldwork_date then raise exception 'Hora de captura fuera de la jornada. Revise el reloj del teléfono.' using errcode='23514'; end if;
 if s.state='closed' and (p_captured_at>s.closed_at or clock_timestamp()>s.closed_at+interval '24 hours') then raise exception 'Pendiente fuera de la ventana permitida de cierre.' using errcode='23514'; end if;
 if p_outcome is null or p_outcome not in ('candidate','blank','invalid','undisclosed','refused') or p_already_voted is distinct from true then raise exception 'Categoría inválida o voto previo no confirmado.' using errcode='23514'; end if;
 if (p_outcome='refused' and p_consent is distinct from false) or (p_outcome<>'refused' and p_consent is distinct from true) then raise exception 'Consentimiento incompatible con la categoría.' using errcode='23514'; end if;
 if p_outcome='candidate' then
   if not exists(select 1 from public.candidates c where c.id=p_candidate_id and c.district_id=p.district_id and c.active and not c.is_template) then raise exception 'Candidatura inválida para su distrito.' using errcode='23514'; end if;
 elsif p_candidate_id is not null then raise exception 'La categoría no admite una candidatura.' using errcode='23514'; end if;
 if not exists(select 1 from public.stations st where st.id=p_station_id and st.district_id=p.district_id and st.active and not st.is_template) then raise exception 'Local no habilitado para producción.' using errcode='23514'; end if;
 insert into public.responses(id,agent_id,district_id,station_id,outcome,candidate_id,consent,already_voted,captured_at)
 values(p_id,p.id,p.district_id,p.station_id,p_outcome,p_candidate_id,p_consent,p_already_voted,p_captured_at)
 on conflict(id) do nothing returning id into new_id;
 if new_id is null then
   select * into oldrow from public.responses where id=p_id;
   if oldrow.agent_id<>p.id or oldrow.station_id is distinct from p_station_id or oldrow.outcome is distinct from p_outcome or oldrow.candidate_id is distinct from p_candidate_id or oldrow.captured_at is distinct from p_captured_at or oldrow.consent is distinct from p_consent or oldrow.already_voted is distinct from p_already_voted then raise exception 'Identificador repetido con contenido distinto.' using errcode='23514'; end if;
   return oldrow.id;
 end if;
 insert into public.audit_log(actor_id,action,subject_id) values(p.id,'capture_received',new_id);
 update public.profiles set last_seen=clock_timestamp() where id=p.id;
 return new_id;
 end$$;

create function public.my_activity() returns jsonb
language plpgsql stable security definer set search_path=''
as $$declare p public.profiles; begin
 p:=app_private.active_profile(); if p.id is null or p.role<>'interviewer' then raise exception 'No autorizado.' using errcode='42501'; end if;
 return jsonb_build_object('total',(select count(*) from public.responses where agent_id=p.id and voided_at is null),
 'records',(select coalesce(jsonb_agg(to_jsonb(r) order by r.received_at desc),'[]'::jsonb) from (select id,outcome,candidate_id,received_at,captured_at,voided_at,void_reason from public.responses where agent_id=p.id order by received_at desc limit 10) r));
 end$$;
create function public.void_response(p_id uuid,p_reason text default 'capture_error') returns void
language plpgsql security definer set search_path=''
as $$declare p public.profiles; r public.responses; begin
 p:=app_private.active_profile(); if p.id is null then raise exception 'No autorizado.' using errcode='42501'; end if;
 select * into r from public.responses where id=p_id for update;
 if r.id is null then raise exception 'Captura no encontrada.' using errcode='P0001'; end if;
 if p.role<>'admin' and (p.role<>'interviewer' or r.agent_id<>p.id or clock_timestamp()>r.received_at+interval '10 minutes') then raise exception 'Solo se anulan capturas propias recibidas hace menos de 10 minutos.' using errcode='42501'; end if;
 if p_reason not in ('capture_error','quality_control') then raise exception 'Motivo inválido.' using errcode='23514'; end if;
 if r.voided_at is not null then return; end if;
 update public.responses set voided_at=clock_timestamp(),voided_by=p.id,void_reason=p_reason where id=p_id;
 insert into public.audit_log(actor_id,action,subject_id,detail) values(p.id,'capture_voided',p_id,jsonb_build_object('reason',p_reason));
 end$$;

create function public.get_dashboard() returns jsonb
language plpgsql stable security definer set search_path=''
as $$declare p public.profiles; result jsonb; begin
 p:=app_private.active_profile(); if p.id is null or p.role not in ('admin','supervisor') then raise exception 'El panel está reservado a coordinación o supervisión.' using errcode='42501'; end if;
 with allowed as (select * from public.districts d where p.role='admin' or d.id=p.district_id),
 rr as materialized (select r.* from public.responses r join allowed d on d.id=r.district_id where r.voided_at is null),
 dc as (select district_id,count(*) total,count(*) filter(where outcome<>'refused') answered,count(*) filter(where outcome='candidate') valid,
   count(*) filter(where outcome='blank') blank,count(*) filter(where outcome='invalid') invalid,count(*) filter(where outcome='undisclosed') undisclosed,count(*) filter(where outcome='refused') refused from rr group by district_id),
 cc as (select candidate_id,count(*) n from rr where outcome='candidate' group by candidate_id),
 ac as (select agent_id,count(*) n,max(received_at) last_received from rr group by agent_id),
 sc as (select station_id,count(*) n from rr group by station_id),
 hc as (select district_id,date_trunc('hour',received_at) AS hour,count(*) n from rr group by district_id,date_trunc('hour',received_at))
 select jsonb_build_object('generated_at',statement_timestamp(),'settings',(select to_jsonb(s) from public.settings s where id=1),
 'districts',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'code',d.code,'name',d.name,'target_agents',15,
 'total',coalesce(dc.total,0),'answered',coalesce(dc.answered,0),'valid',coalesce(dc.valid,0),'blank',coalesce(dc.blank,0),'invalid',coalesce(dc.invalid,0),'undisclosed',coalesce(dc.undisclosed,0),'refused',coalesce(dc.refused,0),
 'candidates',(select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('count',coalesce(cc.n,0)) order by c.sort_order),'[]'::jsonb) from public.candidates c left join cc on cc.candidate_id=c.id where c.district_id=d.id and c.active),
 'agents',(select coalesce(jsonb_agg(to_jsonb(pr)||jsonb_build_object('count',coalesce(ac.n,0),'last_received',ac.last_received) order by pr.slot),'[]'::jsonb) from public.profiles pr left join ac on ac.agent_id=pr.id where pr.district_id=d.id and pr.role='interviewer'),
 'stations',(select coalesce(jsonb_agg(to_jsonb(st)||jsonb_build_object('count',coalesce(sc.n,0)) order by st.name),'[]'::jsonb) from public.stations st left join sc on sc.station_id=st.id where st.district_id=d.id and st.active),
 'hours',(select coalesce(jsonb_agg(jsonb_build_object('hour',hc.hour,'count',hc.n) order by hc.hour),'[]'::jsonb) from hc where hc.district_id=d.id)
 ) order by d.sort_order) from allowed d left join dc on dc.district_id=d.id),'[]'::jsonb)) into result;
 return result; end$$;

create function public.save_settings(p_settings jsonb) returns void
language plpgsql security definer set search_path=''
as $$declare s public.settings; begin
 if not app_private.is_admin() then raise exception 'Solo coordinación.' using errcode='42501'; end if;
 select * into s from public.settings where id=1 for update;
 if s.state<>'setup' then raise exception 'La configuración está bloqueada después de abrir.' using errcode='P0001'; end if;
 if char_length(btrim(coalesce(p_settings->>'methodology','')))<20 then raise exception 'Documente el protocolo de selección y turnos (mínimo 20 caracteres).' using errcode='23514'; end if;
 update public.settings set title=btrim(p_settings->>'title'),contest=btrim(p_settings->>'contest'),fieldwork_date=(p_settings->>'fieldwork_date')::date,
 sample_interval=(p_settings->>'sample_interval')::integer,goal_per_district=(p_settings->>'goal_per_district')::integer,
 methodology=btrim(p_settings->>'methodology'),catalog_confirmed=coalesce((p_settings->>'catalog_confirmed')::boolean,false),updated_at=clock_timestamp() where id=1;
 insert into public.audit_log(actor_id,action) values(auth.uid(),'settings_saved');
 update public.district_signals set version=version+1,changed_at=clock_timestamp();
 end$$;

create function public.save_catalog(p_district_id text,p_candidates jsonb,p_stations jsonb) returns void
language plpgsql security definer set search_path=''
as $$declare s public.settings; item jsonb; cid uuid; sid uuid; kept_c uuid[]:='{}'; kept_s uuid[]:='{}'; nm text; lb text; ord integer:=0; begin
 if not app_private.is_admin() then raise exception 'Solo coordinación.' using errcode='42501'; end if;
 select * into s from public.settings where id=1 for update;
 if s.state<>'setup' or exists(select 1 from public.responses) then raise exception 'No se puede modificar un catálogo con una jornada iniciada.' using errcode='P0001'; end if;
 if not exists(select 1 from public.districts where id=p_district_id) then raise exception 'Distrito inválido.' using errcode='23514'; end if;
 if jsonb_typeof(p_candidates) is distinct from 'array' or jsonb_array_length(p_candidates) not between 2 and 12 or jsonb_typeof(p_stations) is distinct from 'array' or jsonb_array_length(p_stations) not between 1 and 30 then raise exception 'Se requieren 2–12 candidaturas y 1–30 locales.' using errcode='23514'; end if;
 -- Deactivate names first so rename/swap operations are transactional, not order-sensitive.
 update public.candidates set active=false where district_id=p_district_id;
 for item in select value from jsonb_array_elements(p_candidates) loop
   cid:=coalesce(nullif(item->>'id','')::uuid,gen_random_uuid()); nm:=btrim(coalesce(item->>'name','')); lb:=btrim(coalesce(item->>'list_label',''));
   if exists(select 1 from public.candidates where id=cid and district_id<>p_district_id) or cid=any(kept_c) then raise exception 'Identificador de candidatura inválido o repetido.' using errcode='23514'; end if;
   insert into public.candidates(id,district_id,name,list_label,sort_order,active,is_template)
     values(cid,p_district_id,nm,lb,ord,true,(nm||' '||lb)~*'(ejemplo|configurar|pendiente)' or nm~*'^candidatura [abc]$')
   on conflict(id) do update set name=excluded.name,list_label=excluded.list_label,sort_order=excluded.sort_order,active=true,is_template=excluded.is_template;
   kept_c:=array_append(kept_c,cid); ord:=ord+1;
 end loop;
 -- Assigned stations must survive; a missing/foreign ID must not move people silently.
 for item in select value from jsonb_array_elements(p_stations) loop
   sid:=coalesce(nullif(item->>'id','')::uuid,gen_random_uuid());
   if sid=any(kept_s) or exists(select 1 from public.stations where id=sid and district_id<>p_district_id) then raise exception 'Identificador de local inválido o repetido.' using errcode='23514'; end if;
   kept_s:=array_append(kept_s,sid);
 end loop;
 if exists(select 1 from public.profiles p join public.stations st on st.id=p.station_id where st.district_id=p_district_id and not(st.id=any(kept_s))) then raise exception 'No puede quitar un local asignado a un puesto; reasigne antes.' using errcode='23514'; end if;
 update public.stations set active=false where district_id=p_district_id;
 ord:=1;
 for item in select value from jsonb_array_elements(p_stations) loop
   sid:=kept_s[ord]; nm:=btrim(coalesce(item->>'name',''));
   insert into public.stations(id,district_id,name,active,is_template) values(sid,p_district_id,nm,true,nm~*'(ejemplo|configurar|pendiente)')
     on conflict(id) do update set name=excluded.name,active=true,is_template=excluded.is_template;
   ord:=ord+1;
 end loop;
 update public.settings set catalog_confirmed=false,updated_at=clock_timestamp() where id=1;
 insert into public.audit_log(actor_id,action,detail) values(auth.uid(),'catalog_saved',jsonb_build_object('district_id',p_district_id));
 update public.district_signals set version=version+1,changed_at=clock_timestamp() where district_id=p_district_id;
 end$$;

create function public.set_fieldwork_state(p_state text) returns void
language plpgsql security definer set search_path=''
as $$declare s public.settings; begin
 if not app_private.is_admin() then raise exception 'Solo coordinación.' using errcode='42501'; end if;
 select * into s from public.settings where id=1 for update;
 if p_state='open' then
   if s.state<>'setup' then raise exception 'Solo se abre una jornada en preparación.' using errcode='P0001'; end if;
   if not s.catalog_confirmed or s.fieldwork_date is null or s.fieldwork_date<>(clock_timestamp() at time zone 'America/Asuncion')::date or char_length(s.methodology)<20 or s.contest~*'(confirmar|configurar|ejemplo)' then raise exception 'Confirme el cargo, los catálogos y el protocolo. La apertura debe ser en la fecha configurada.' using errcode='23514'; end if;
   if exists(select 1 from public.districts d where (select count(*) from public.candidates c where c.district_id=d.id and c.active and not c.is_template)<2 or (select count(*) from public.profiles p where p.district_id=d.id and p.role='interviewer')<>15) then raise exception 'Cada distrito necesita candidaturas verificadas y sus 15 puestos.' using errcode='23514'; end if;
   if exists(select 1 from public.candidates where active and is_template) or exists(select 1 from public.stations where active and is_template) or exists(select 1 from public.profiles p join public.stations st on st.id=p.station_id where p.role='interviewer' and (not st.active or st.is_template)) then raise exception 'Todavía hay candidaturas o locales de ejemplo o no habilitados.' using errcode='23514'; end if;
   update public.settings set state='open',opened_at=clock_timestamp(),closed_at=null,updated_at=clock_timestamp() where id=1;
 elsif p_state='closed' then
   if s.state<>'open' then raise exception 'Solo se cierra una jornada abierta.' using errcode='P0001'; end if;
   update public.settings set state='closed',closed_at=clock_timestamp(),updated_at=clock_timestamp() where id=1;
 else raise exception 'Transición de estado no permitida.' using errcode='23514'; end if;
 insert into public.audit_log(actor_id,action,detail) values(auth.uid(),'fieldwork_state_changed',jsonb_build_object('state',p_state));
 update public.district_signals set version=version+1,changed_at=clock_timestamp();
 end$$;

create function public.set_assignment(p_user_id uuid,p_station_id uuid) returns void
language plpgsql security definer set search_path=''
as $$declare p public.profiles; s public.settings; begin
 if not app_private.is_admin() then raise exception 'Solo coordinación.' using errcode='42501'; end if;
 select * into s from public.settings where id=1 for update;
 if s.state<>'setup' then raise exception 'Las asignaciones están bloqueadas después de abrir.' using errcode='P0001'; end if;
 select * into p from public.profiles where id=p_user_id and role='interviewer' for update;
 if p.id is null or not exists(select 1 from public.stations where id=p_station_id and district_id=p.district_id and active) then raise exception 'Puesto o local inválido.' using errcode='23514'; end if;
 update public.profiles set station_id=p_station_id where id=p_user_id;
 insert into public.audit_log(actor_id,action,subject_id,detail) values(auth.uid(),'assignment_changed',p_user_id,jsonb_build_object('station_id',p_station_id));
 end$$;
create function public.set_account_active(p_user_id uuid,p_active boolean) returns void
language plpgsql security definer set search_path=''
as $$begin
 if not app_private.is_admin() then raise exception 'Solo coordinación.' using errcode='42501'; end if;
 if p_user_id=auth.uid() or p_active is null then raise exception 'Operación no permitida.' using errcode='23514'; end if;
 update public.profiles set active=p_active where id=p_user_id and role in ('interviewer','supervisor');
 if not found then raise exception 'Puesto no encontrado o protegido.' using errcode='P0001'; end if;
 insert into public.audit_log(actor_id,action,subject_id,detail) values(auth.uid(),'account_access_changed',p_user_id,jsonb_build_object('active',p_active));
 update public.district_signals set version=version+1,changed_at=clock_timestamp();
 end$$;
create function public.log_export(p_kind text) returns void
language plpgsql security definer set search_path=''
as $$declare p public.profiles; begin
 p:=app_private.active_profile();
 if p.id is null or not(p.role='admin' or (p.role='supervisor' and p_kind='team_activity')) then raise exception 'No autorizado.' using errcode='42501'; end if;
 if p_kind not in ('district_aggregates','team_activity') then raise exception 'Tipo de exportación inválido.' using errcode='23514'; end if;
 insert into public.audit_log(actor_id,action,detail) values(p.id,'export_requested',jsonb_build_object('kind',p_kind));
 end$$;

-- Close PostgreSQL's default PUBLIC EXECUTE on all functions introduced here.
revoke all on function app_private.active_profile(),app_private.is_admin(),app_private.has_access_to(text),app_private.profile_guard(),app_private.signal_change() from public,anon,authenticated;
grant execute on function app_private.active_profile(),app_private.is_admin(),app_private.has_access_to(text) to authenticated;
do $$declare f record; begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('bootstrap','ping','submit_response','my_activity','void_response','get_dashboard','save_settings','save_catalog','set_fieldwork_state','set_assignment','set_account_active','log_export') loop
 execute format('revoke all on function %s from public, anon, authenticated',f.signature);
 execute format('grant execute on function %s to authenticated',f.signature);
 end loop;
end$$;
-- Realtime carries ONLY a per-district invalidation counter, not an individual response.
do $$begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime') and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='district_signals') then
   alter publication supabase_realtime add table public.district_signals;
 end if;
end$$;
commit;

-- Pulso 2.0 — run after 001, in a dedicated project BEFORE fieldwork.
-- Refuses to replace a catalogue containing observations. No automatic deletion.
begin;
do $$begin
 if exists(select 1 from public.responses) or exists(select 1 from public.settings where state<>'setup') then
  raise exception 'V2 requiere una jornada vacía en preparación. No se modificaron datos. Use un proyecto nuevo o planifique una migración.';
 end if;
end$$;
alter table public.settings add column viewer_enabled boolean not null default false;
alter table public.profiles add column display_name text not null default '' check(char_length(display_name)<=100);
do $$declare c record; begin
 for c in select conname from pg_constraint where conrelid='public.profiles'::regclass and contype='c' and pg_get_constraintdef(oid) like '%role%' loop
  execute format('alter table public.profiles drop constraint %I',c.conname);
 end loop;
end$$;
update public.profiles set role='viewer' where role='supervisor';
alter table public.profiles add constraint profiles_role_v2 check(role in ('admin','viewer','interviewer'));
alter table public.profiles add constraint profiles_shape_v2 check(
 (role='admin' and district_id is null and station_id is null and slot is null) or
 (role='viewer' and station_id is null and slot is null) or
 (role='interviewer' and district_id is not null and station_id is not null and slot is not null and slot between 1 and 15));
alter table public.stations
 add column code text not null default '' check(char_length(code)<=60),
 add column address text not null default '' check(char_length(address)<=250),
 add column point_label text not null default '' check(char_length(point_label)<=150),
 add column latitude double precision check(latitude between -90 and 90),
 add column longitude double precision check(longitude between -180 and 180),
 add constraint station_coordinate_pair check((latitude is null)=(longitude is null));
alter table public.responses
 add column started_at timestamptz,
 add column station_name_snapshot text not null default '',
 add column station_address_snapshot text not null default '',
 add column point_snapshot text not null default '',
 add column geo_status text not null default 'not_requested' check(geo_status in ('not_requested','granted','denied','unavailable','stale')),
 add column latitude double precision check(latitude between -90 and 90),
 add column longitude double precision check(longitude between -180 and 180),
 add column accuracy_m double precision check(accuracy_m between 0 and 100000),
 add column geo_captured_at timestamptz,
 add constraint response_geo_v2 check((geo_status='granted' and latitude is not null and longitude is not null and accuracy_m is not null and geo_captured_at is not null) or
 (geo_status<>'granted' and latitude is null and longitude is null and accuracy_m is null and geo_captured_at is null)),
 add constraint response_start_v2 check(started_at is null or (started_at<=captured_at and started_at>=captured_at-interval '2 hours'));
create index responses_captured_v2 on public.responses(district_id,station_id,captured_at) where voided_at is null;
create index responses_journal_v2 on public.responses(received_at desc,id desc);

-- Catalogue supplied by the operator on 22 September 2026. Not certified by TSJE.
delete from public.candidates;
insert into public.candidates(district_id,name,list_label,sort_order,is_template) values
('cde','Rigo Chamorro','Lista 1',0,false),('cde','Dani Mujica','Lista 123',1,false),
('hernandarias','Oscar “Melli” González','Lista 1',0,false),('hernandarias','José Castillo','Lista 2026',1,false),
('minga','César Paredes','Lista 1',0,false),('minga','Mónica Ramírez','Lista 123',1,false),
('minga','Roberto Almiron','Lista 6',2,false),('minga','Tania Mabel Meza','Lista 44',3,false),
('franco','Arnold Ramírez','Lista 1',0,false),('franco','Roya Torres','Lista 2',1,false),
('franco','Henry González','Lista 3',2,false),('franco','Mabel Otazú','Lista 123',3,false);
update public.settings set title='Municipales 2026 · Alto Paraná',contest='Intendencia municipal',fieldwork_date='2026-10-04',catalog_confirmed=false;
-- Existing sample stations MUST be replaced/renamed with verified real data.

create or replace function app_private.has_access_to(d text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles p where p.id=auth.uid() and p.active and
 (p.role='admin' or (p.role='interviewer' and p.district_id=d) or
 (p.role='viewer' and (p.district_id is null or p.district_id=d) and (select viewer_enabled from public.settings where id=1))))$$;
drop policy profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated using((app_private.active_profile()).id is not null and (id=auth.uid() or app_private.is_admin()));

create or replace function public.bootstrap() returns jsonb
language plpgsql stable security definer set search_path='' as $$declare p public.profiles;begin
 p:=app_private.active_profile();if p.id is null then raise exception 'Cuenta no habilitada.' using errcode='42501';end if;
 return jsonb_build_object('profile',to_jsonb(p),'settings',(select to_jsonb(s) from public.settings s where id=1),
 'districts',(select coalesce(jsonb_agg(to_jsonb(d) order by d.sort_order),'[]'::jsonb) from public.districts d where p.role='admin' or (p.role='viewer' and p.district_id is null) or d.id=p.district_id),
 'candidates',(select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order),'[]'::jsonb) from public.candidates c where c.active and (p.role='admin' or (p.role='viewer' and p.district_id is null) or c.district_id=p.district_id)),
 'stations',(select coalesce(jsonb_agg(to_jsonb(s) order by s.name),'[]'::jsonb) from public.stations s where s.active and (p.role='admin' or (p.role='viewer' and p.district_id is null) or s.district_id=p.district_id)));
end$$;

create function public.submit_response_v2(p_event jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare rid uuid; uid uuid; oldrow public.responses; st public.stations; started timestamptz; captured timestamptz;
 gs text; lat double precision; lon double precision; acc double precision; gt timestamptz;
begin
 if (app_private.active_profile()).role is distinct from 'interviewer' then raise exception 'Solo encuestadores activos.' using errcode='42501';end if;
 rid:=(p_event->>'id')::uuid;
 if rid is null then raise exception 'Falta identificador.' using errcode='23514';end if;
 -- Serialize retries of the SAME UUID, including their location metadata.
 perform pg_advisory_xact_lock(hashtextextended(rid::text,0));
 started:=(p_event->>'started_at')::timestamptz;captured:=(p_event->>'captured_at')::timestamptz;
 gs:=coalesce(p_event->>'geo_status','not_requested');lat:=(p_event->>'latitude')::double precision;lon:=(p_event->>'longitude')::double precision;
 acc:=(p_event->>'accuracy_m')::double precision;gt:=(p_event->>'geo_captured_at')::timestamptz;
 if started is null or captured is null or started>captured or started<captured-interval '2 hours' then raise exception 'Hora de inicio inválida.' using errcode='23514';end if;
 if gs not in ('not_requested','granted','denied','unavailable','stale') then raise exception 'Estado GPS inválido.' using errcode='23514';end if;
 if gs='granted' then
  if lat is null or lon is null or acc is null or gt is null or not(lat between -90 and 90) or not(lon between -180 and 180) or not(acc between 0 and 100000) or gt>captured+interval '30 seconds' or gt<captured-interval '15 minutes' then raise exception 'Ubicación operativa inválida o antigua.' using errcode='23514';end if;
 elsif lat is not null or lon is not null or acc is not null or gt is not null then raise exception 'GPS no autorizado: no envíe coordenadas.' using errcode='23514';end if;
 select * into oldrow from public.responses where id=rid;
 if found and (oldrow.started_at is distinct from started or oldrow.geo_status is distinct from gs or oldrow.latitude is distinct from lat or oldrow.longitude is distinct from lon or oldrow.accuracy_m is distinct from acc or oldrow.geo_captured_at is distinct from gt) then raise exception 'UUID repetido con metadatos distintos.' using errcode='23514';end if;
 -- v1 validates DB-owned role, date, consent, candidate/district and assigned station;
 -- it also compares every original field for idempotent retries.
 uid:=public.submit_response(rid,(p_event->>'station_id')::uuid,p_event->>'outcome',(p_event->>'candidate_id')::uuid,captured,(p_event->>'consent')::boolean,(p_event->>'already_voted')::boolean);
 if oldrow.id is null then
  select * into st from public.stations where id=(p_event->>'station_id')::uuid;
  update public.responses set started_at=started,station_name_snapshot=st.name,station_address_snapshot=st.address,point_snapshot=st.point_label,geo_status=gs,latitude=lat,longitude=lon,accuracy_m=acc,geo_captured_at=gt where id=uid;
 end if;
 return uid;
end$$;
-- No client can bypass v2 validation through the legacy RPC.
revoke execute on function public.submit_response(uuid,uuid,text,uuid,timestamptz,boolean,boolean) from public,anon,authenticated;

create function public.get_dashboard_v2(p_station_id uuid default null,p_from timestamptz default null,p_to timestamptz default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$declare p public.profiles;result jsonb;begin
 p:=app_private.active_profile();
 if p.id is null or p.role not in ('admin','viewer') then raise exception 'Panel reservado a administradores y viewers.' using errcode='42501';end if;
 if p.role='viewer' and not(select viewer_enabled from public.settings where id=1) then raise exception 'Acceso viewer aún no habilitado por administración.' using errcode='42501';end if;
 if p_from is not null and p_to is not null and p_from>p_to then raise exception 'Intervalo inválido.' using errcode='23514';end if;
 if p_station_id is not null and not exists(select 1 from public.stations s where s.id=p_station_id and s.active and app_private.has_access_to(s.district_id)) then raise exception 'Local fuera de su alcance.' using errcode='42501';end if;
 with allowed as (select d.* from public.districts d where app_private.has_access_to(d.id) and (p_station_id is null or d.id=(select district_id from public.stations where id=p_station_id))),
 rr as materialized(select r.* from public.responses r join allowed d on d.id=r.district_id where r.voided_at is null and (p_station_id is null or r.station_id=p_station_id) and (p_from is null or r.captured_at>=p_from) and (p_to is null or r.captured_at<=p_to)),
 dc as(select district_id,count(*) total,count(*) filter(where outcome<>'refused') answered,count(*) filter(where outcome='candidate') valid,count(*) filter(where outcome='blank') blank,count(*) filter(where outcome='invalid') invalid,count(*) filter(where outcome='undisclosed') undisclosed,count(*) filter(where outcome='refused') refused from rr group by district_id),
 cc as(select candidate_id,count(*) n from rr where outcome='candidate' group by candidate_id),
 ac as(select agent_id,count(*) n,max(received_at) last_received,max(captured_at) last_captured from rr group by agent_id),
 sc as(select station_id,count(*) n,count(*) filter(where outcome<>'refused') answered,count(*) filter(where outcome='candidate') valid,max(received_at) last_received from rr group by station_id),
 hc as(select district_id,date_trunc('hour',received_at) AS hour,count(*) n from rr group by district_id,date_trunc('hour',received_at)),
 ch as(select district_id,date_trunc('hour',captured_at) AS hour,count(*) n from rr group by district_id,date_trunc('hour',captured_at))
 select jsonb_build_object('generated_at',statement_timestamp(),'settings',(select to_jsonb(s) from public.settings s where id=1),'filters',jsonb_build_object('station_id',p_station_id,'from',p_from,'to',p_to),
 'districts',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'code',d.code,'name',d.name,'target_agents',15,
 'total',coalesce(dc.total,0),'answered',coalesce(dc.answered,0),'valid',coalesce(dc.valid,0),'blank',coalesce(dc.blank,0),'invalid',coalesce(dc.invalid,0),'undisclosed',coalesce(dc.undisclosed,0),'refused',coalesce(dc.refused,0),
 'candidates',(select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('count',coalesce(cc.n,0)) order by c.sort_order),'[]'::jsonb) from public.candidates c left join cc on cc.candidate_id=c.id where c.district_id=d.id and c.active),
 'agents',case when p.role='admin' then (select coalesce(jsonb_agg(to_jsonb(pr)||jsonb_build_object('count',coalesce(ac.n,0),'last_received',ac.last_received,'last_captured',ac.last_captured) order by pr.slot),'[]'::jsonb) from public.profiles pr left join ac on ac.agent_id=pr.id where pr.district_id=d.id and pr.role='interviewer' and (p_station_id is null or pr.station_id=p_station_id)) else '[]'::jsonb end,
 'stations',(select coalesce(jsonb_agg(to_jsonb(st)||jsonb_build_object('count',coalesce(sc.n,0),'answered',coalesce(sc.answered,0),'valid',coalesce(sc.valid,0),'last_received',sc.last_received,
 'candidates',(select coalesce(jsonb_agg(to_jsonb(c)||jsonb_build_object('count',(select count(*) from rr where station_id=st.id and candidate_id=c.id)) order by c.sort_order),'[]'::jsonb) from public.candidates c where c.district_id=d.id and c.active)) order by st.name),'[]'::jsonb) from public.stations st left join sc on sc.station_id=st.id where st.district_id=d.id and st.active and (p_station_id is null or st.id=p_station_id)),
 'hours',(select coalesce(jsonb_agg(jsonb_build_object('hour',hc.hour,'count',hc.n) order by hc.hour),'[]'::jsonb) from hc where hc.district_id=d.id),
 'capture_hours',(select coalesce(jsonb_agg(jsonb_build_object('hour',ch.hour,'count',ch.n) order by ch.hour),'[]'::jsonb) from ch where ch.district_id=d.id)
 ) order by d.sort_order) from allowed d left join dc on dc.district_id=d.id),'[]'::jsonb)) into result;
 return result;
end$$;
create or replace function public.get_dashboard() returns jsonb language sql stable security definer set search_path='' as $$select public.get_dashboard_v2()$$;

create function public.get_records_v2(p_district_id text default null,p_station_id uuid default null,p_agent_id uuid default null,p_before timestamptz default null,p_before_id uuid default null,p_limit integer default 100) returns jsonb
language plpgsql stable security definer set search_path='' as $$declare p public.profiles;result jsonb;begin
 p:=app_private.active_profile();if p.id is null or p.role not in ('admin','interviewer') then raise exception 'Registro reservado a administración o capturas propias.' using errcode='42501';end if;
 if p_limit is null or p_limit not between 1 and 500 then raise exception 'Límite inválido.' using errcode='23514';end if;
 if (p_before is null)<>(p_before_id is null) then raise exception 'Cursor incompleto.' using errcode='23514';end if;
 if p.role='interviewer' then
  if (p_agent_id is not null and p_agent_id<>p.id) or (p_district_id is not null and p_district_id<>p.district_id) or (p_station_id is not null and p_station_id<>p.station_id) then raise exception 'Solo capturas propias.' using errcode='42501';end if;
 end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.received_at desc,x.id desc),'[]'::jsonb) into result from
 (select r.*,pr.code agent_code,pr.display_name agent_name,st.code station_code,c.name candidate_name,c.list_label
 from public.responses r join public.profiles pr on pr.id=r.agent_id join public.stations st on st.id=r.station_id left join public.candidates c on c.id=r.candidate_id
 where (p.role='admin' or r.agent_id=p.id) and (p_district_id is null or r.district_id=p_district_id) and (p_station_id is null or r.station_id=p_station_id) and (p_agent_id is null or r.agent_id=p_agent_id)
 and (p_before is null or (r.received_at,r.id)<(p_before,p_before_id)) order by r.received_at desc,r.id desc limit p_limit) x;
 return result;
end$$;

create function public.list_accounts_v2() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not app_private.is_admin() then raise exception 'Solo administración.' using errcode='42501';end if;
 return(select coalesce(jsonb_agg(to_jsonb(p) order by p.role,p.code),'[]'::jsonb) from public.profiles p);
end$$;
create function public.set_viewer_access(p_enabled boolean) returns void language plpgsql security definer set search_path='' as $$begin
 if not app_private.is_admin() then raise exception 'Solo administración.' using errcode='42501';end if;
 if p_enabled is null then raise exception 'Valor inválido.' using errcode='23514';end if;
 update public.settings set viewer_enabled=p_enabled,updated_at=clock_timestamp() where id=1;
 insert into public.audit_log(actor_id,action,detail) values(auth.uid(),'viewer_access_changed',jsonb_build_object('enabled',p_enabled));
 update public.district_signals set version=version+1,changed_at=clock_timestamp();
end$$;
create function public.set_operator_label(p_user_id uuid,p_name text) returns void language plpgsql security definer set search_path='' as $$begin
 if not app_private.is_admin() then raise exception 'Solo administración.' using errcode='42501';end if;
 update public.profiles set display_name=btrim(p_name) where id=p_user_id;
 if not found then raise exception 'Cuenta no encontrada.';end if;
 insert into public.audit_log(actor_id,action,subject_id) values(auth.uid(),'operator_label_changed',p_user_id);
end$$;
create or replace function public.set_account_active(p_user_id uuid,p_active boolean) returns void
language plpgsql security definer set search_path='' as $$begin
 if not app_private.is_admin() then raise exception 'Solo administración.' using errcode='42501';end if;
 if p_user_id=auth.uid() or p_active is null then raise exception 'Operación no permitida.' using errcode='23514';end if;
 update public.profiles set active=p_active where id=p_user_id and role in ('interviewer','viewer');
 if not found then raise exception 'Cuenta no encontrada o protegida.' using errcode='P0001';end if;
 insert into public.audit_log(actor_id,action,subject_id,detail) values(auth.uid(),'account_access_changed',p_user_id,jsonb_build_object('active',p_active));
 update public.district_signals set version=version+1,changed_at=clock_timestamp();
end$$;

create or replace function public.save_catalog(p_district_id text,p_candidates jsonb,p_stations jsonb) returns void
language plpgsql security definer set search_path=''
as $$declare s public.settings; item jsonb; cid uuid; sid uuid; kept_c uuid[]:='{}'; kept_s uuid[]:='{}'; nm text; lb text; ord integer:=0; begin
 if not app_private.is_admin() then raise exception 'Solo coordinación.' using errcode='42501'; end if;
 select * into s from public.settings where id=1 for update;
 if s.state<>'setup' or exists(select 1 from public.responses) then raise exception 'No se puede modificar un catálogo con una jornada iniciada.' using errcode='P0001'; end if;
 if not exists(select 1 from public.districts where id=p_district_id) then raise exception 'Distrito inválido.' using errcode='23514'; end if;
 if jsonb_typeof(p_candidates) is distinct from 'array' or jsonb_array_length(p_candidates) not between 2 and 12 or jsonb_typeof(p_stations) is distinct from 'array' or jsonb_array_length(p_stations) not between 1 and 200 then raise exception 'Se requieren 2–12 candidaturas y 1–200 locales.' using errcode='23514'; end if;
 -- Deactivate names first so rename/swap operations are transactional, not order-sensitive.
 update public.candidates set active=false where district_id=p_district_id;
 for item in select value from jsonb_array_elements(p_candidates) loop
   cid:=coalesce(nullif(item->>'id','')::uuid,gen_random_uuid()); nm:=btrim(coalesce(item->>'name','')); lb:=btrim(coalesce(item->>'list_label',''));
   if exists(select 1 from public.candidates where id=cid and district_id<>p_district_id) or cid=any(kept_c) then raise exception 'Identificador de candidatura inválido o repetido.' using errcode='23514'; end if;
   insert into public.candidates(id,district_id,name,list_label,sort_order,active,is_template)
     values(cid,p_district_id,nm,lb,ord,true,(nm||' '||lb)~*'(ejemplo|configurar|pendiente)' or nm~*'^candidatura [abc]$')
   on conflict(id) do update set name=excluded.name,list_label=excluded.list_label,sort_order=excluded.sort_order,active=true,is_template=excluded.is_template;
   kept_c:=array_append(kept_c,cid); ord:=ord+1;
 end loop;
 -- Assigned stations must survive; a missing/foreign ID must not move people silently.
 for item in select value from jsonb_array_elements(p_stations) loop
   sid:=coalesce(nullif(item->>'id','')::uuid,gen_random_uuid());
   if sid=any(kept_s) or exists(select 1 from public.stations where id=sid and district_id<>p_district_id) then raise exception 'Identificador de local inválido o repetido.' using errcode='23514'; end if;
   kept_s:=array_append(kept_s,sid);
 end loop;
 if exists(select 1 from public.profiles p join public.stations st on st.id=p.station_id where st.district_id=p_district_id and not(st.id=any(kept_s))) then raise exception 'No puede quitar un local asignado a un puesto; reasigne antes.' using errcode='23514'; end if;
 update public.stations set active=false where district_id=p_district_id;
 ord:=1;
 for item in select value from jsonb_array_elements(p_stations) loop
   sid:=kept_s[ord]; nm:=btrim(coalesce(item->>'name',''));
   insert into public.stations(id,district_id,name,active,is_template,code,address,point_label,latitude,longitude)
     values(sid,p_district_id,nm,true,nm~*'(ejemplo|configurar|pendiente|práctica|NO OFICIAL)' or char_length(btrim(coalesce(item->>'address','')))<5,
       btrim(coalesce(item->>'code','')),btrim(coalesce(item->>'address','')),btrim(coalesce(item->>'point_label','')),
       nullif(item->>'latitude','')::double precision,nullif(item->>'longitude','')::double precision)
     on conflict(id) do update set name=excluded.name,active=true,is_template=excluded.is_template,code=excluded.code,address=excluded.address,point_label=excluded.point_label,latitude=excluded.latitude,longitude=excluded.longitude;
   ord:=ord+1;
 end loop;
 update public.settings set catalog_confirmed=false,updated_at=clock_timestamp() where id=1;
 insert into public.audit_log(actor_id,action,detail) values(auth.uid(),'catalog_saved',jsonb_build_object('district_id',p_district_id));
 update public.district_signals set version=version+1,changed_at=clock_timestamp() where district_id=p_district_id;
 end$$;


-- Export is admin-only; nothing is published by these functions.
create or replace function public.log_export(p_kind text) returns void language plpgsql security definer set search_path='' as $$begin
 if not app_private.is_admin() then raise exception 'Solo administración.' using errcode='42501';end if;
 if p_kind not in ('district_aggregates','team_activity','station_aggregates','records') then raise exception 'Tipo inválido.' using errcode='23514';end if;
 insert into public.audit_log(actor_id,action,detail) values(auth.uid(),'export_requested',jsonb_build_object('kind',p_kind));
end$$;
do $$declare f record;begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in
 ('submit_response_v2','get_dashboard_v2','get_records_v2','list_accounts_v2','set_viewer_access','set_operator_label') loop
 execute format('revoke all on function %s from public,anon,authenticated',f.signature);
 execute format('grant execute on function %s to authenticated',f.signature);
 end loop;
end$$;
commit;
