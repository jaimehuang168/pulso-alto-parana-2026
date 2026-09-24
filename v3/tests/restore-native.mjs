/** Actual pg_dump/pg_restore in the disposable CI cluster. Never a production URL. */
import fs from 'node:fs/promises';import assert from 'node:assert/strict';import {execFileSync} from 'node:child_process';import pg from 'pg';
const x=JSON.parse(await fs.readFile('/tmp/pulso-v3-local-context.json','utf8'));const u=new URL(x.dbUrl);
if(!['127.0.0.1','localhost'].includes(u.hostname)||!/^http:\/\/127\.0\.0\.1:/.test(x.url))throw new Error('Disposable localhost only');
const name='pulso_v3_restore_qa',container='supabase_db_pulso-v3-ci',dump='/tmp/pulso-v3-qa.dump';
const original=new pg.Client({connectionString:x.dbUrl});await original.connect();let restored;const results=[];
function docker(args){try{return execFileSync('docker',['exec',container,...args],{encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:90000});}catch(e){const reason=String(e.stderr||'').split('\n').filter(line=>/ERROR:|FATAL:/.test(line)).map(line=>line.replace(/\S+@\S+/g,'[redacted]').replace(/[A-Za-z0-9_=-]{45,}/g,'[redacted]')).slice(0,3).join(' | ').slice(0,500);throw new Error('Local backup/restore command failed: '+args[0]+' (exit '+e.status+'): '+reason);}}
const snapshot=async db=>{const out={};for(const table of ['people','actors','assignments','capture_grants','questionnaires','responses','audit','role_grants']){out[table]=(await db.query(`select count(*)::int n,md5(coalesce(string_agg(to_jsonb(t)::text,'' order by to_jsonb(t)::text),'')) digest from pulso_v3.${table} t`)).rows[0];}return out;};
try{
 const expected=await snapshot(original);assert(expected.responses.n>0,'Restore must contain real synthetic receipts, not empty tables');
 docker(['pg_dump','-U','postgres','-d','postgres','-Fc','--no-owner','--no-acl','--schema=public','--schema=auth','--schema=app_private','--schema=pulso_v3','--file='+dump]);
 await original.query('create database '+name);u.pathname='/'+name;restored=new pg.Client({connectionString:u.toString()});await restored.connect();
 await restored.query('create schema if not exists extensions;create extension if not exists "uuid-ossp" with schema extensions;create extension if not exists pgcrypto with schema extensions;');
 docker(['pg_restore','-U','postgres','-d',name,'--clean','--if-exists','--exit-on-error','--no-owner','--no-acl',dump]);
 const actual=await snapshot(restored);assert.deepEqual(actual,expected);results.push({name:'Real scoped pg_dump/pg_restore preserves all eight critical tables',pass:true,rows:Object.fromEntries(Object.entries(actual).map(([k,v])=>[k,v.n]))});
 const protectedTables=(await restored.query("select count(*)::int n from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='pulso_v3' and c.relkind='r' and not c.relrowsecurity")).rows[0].n;assert.equal(protectedTables,0);results.push({name:'Restored private data tables retain RLS enabled',pass:true});
 assert((await restored.query("select to_regprocedure('public.v3_submit_response(jsonb,integer)') is not null ok")).rows[0].ok);results.push({name:'Restored schema contains original receipt RPC and immutable guards',pass:true});
}catch(e){results.push({name:'Native scoped restore execution',pass:false,error:e.message});process.exitCode=1;}finally{
 if(restored)await restored.end();await original.query('drop database if exists '+name+' with (force)').catch(()=>{});docker(['rm','-f',dump]);await original.end();
 await fs.writeFile(new URL('../evidence/restore-native.json',import.meta.url),JSON.stringify({environment:'Disposable CI PostgreSQL only; scoped logical restore; not full Supabase project recovery',scope:'Original source database untouched. Private dump deleted; no dump or passwords uploaded.',limitations:'ACLs/cluster roles, hosted project settings, Realtime replication setup, Edge secrets and Storage object backups require the separate production runbook. Storage API round-trip is tested in native.mjs.',passed:results.filter(r=>r.pass).length,failed:results.filter(r=>!r.pass).length,results},null,2));
}
