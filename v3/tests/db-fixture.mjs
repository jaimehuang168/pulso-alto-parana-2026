import fs from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
export const admin='11111111-1111-4111-8111-111111111111';
export const adminSession='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
export async function database(){
 const db=new PGlite();
 await db.exec(`CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS;
 CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz,raw_app_meta_data jsonb NOT NULL DEFAULT '{}');
 CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid REFERENCES auth.users(id));
 CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
 CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT coalesce(nullif(auth.jwt()->>'sub',''),nullif(current_setting('request.jwt.claim.sub',true),''))::uuid $$;
 GRANT USAGE ON SCHEMA auth TO anon,authenticated,service_role;
 CREATE PUBLICATION supabase_realtime;`);
 for(const f of ['001_schema.sql','002_municipales_2026.sql','003_safeupdate_compatibility.sql']) await db.exec(await fs.readFile(new URL('../../supabase/migrations/'+f,import.meta.url),'utf8'));
 await db.query(`INSERT INTO auth.users(id,email,email_confirmed_at) VALUES($1,'qa-admin@example.invalid',now());`,[admin]);
 await db.query('INSERT INTO auth.sessions VALUES($1,$2)',[adminSession,admin]);
 await db.query(`INSERT INTO public.profiles(id,code,role,active) VALUES($1,'COORD-01','admin',true)`,[admin]);
 for(const f of ['004_v3_expand.sql','005_v3_api.sql','006_v3_enrollment.sql','007_v3_cutover.sql','008_v3_storage.sql']) {console.log('INSTALL',f);await db.exec(await fs.readFile(new URL('../../supabase/migrations/'+f,import.meta.url),'utf8'));}
 return db;
}
export async function as(db,uid,session,sql,args=[]){
 await db.exec('BEGIN; SET LOCAL ROLE authenticated;');
 try {
  await db.query("SELECT set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:uid,session_id:session,role:'authenticated'})]);
  const res=await db.query(sql,args);await db.exec('COMMIT');return res.rows;
 }catch(e){await db.exec('ROLLBACK');throw e;}
}
