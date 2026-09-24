import {database,as,admin,adminSession} from './db-fixture.mjs';
try { const db=await database();console.log(JSON.stringify(await as(db,admin,adminSession,'select public.v3_bootstrap() b'),null,2).slice(0,1200));await db.close();} catch(e){console.error('DB_ERROR', e.message,e.code,e.where,e.internalQuery);process.exit(1)}
