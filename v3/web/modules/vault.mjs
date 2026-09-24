/** Per-user, per-environment encrypted IndexedDB. Never touches Pulso V2 databases. */
import {digest,canonical,assertReceipt} from './core.mjs';
const encode=new TextEncoder(),decode=new TextDecoder();
const b64=a=>btoa(String.fromCharCode(...new Uint8Array(a)));
const bytes=s=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
const iterations=310000;
function request(r){return new Promise((resolve,reject)=>{r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error||new Error('V3_STORAGE_FAILED'));});}
export class Vault{
 constructor(environment,user){this.environment=environment;this.user=user;this.key=null;this.db=null;this.prefix=null;}
 async open(){this.prefix=await digest(this.environment+'|'+this.user);const r=indexedDB.open('pulso-v3-encrypted',1);r.onupgradeneeded=()=>{for(const n of ['keys','entries'])r.result.createObjectStore(n,{keyPath:'id'});};this.db=await request(r);this.db.onversionchange=()=>this.db.close();return this;}
 async get(store,id){return request(this.db.transaction(store).objectStore(store).get(id));}
 async put(store,value){return new Promise((resolve,reject)=>{const t=this.db.transaction(store,'readwrite');t.objectStore(store).put(value);t.oncomplete=()=>resolve(value);t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error||new Error('V3_STORAGE_FAILED'));});}
 async exists(){return !!await this.get('keys',this.prefix);}
 async derive(pass,salt){const base=await crypto.subtle.importKey('raw',encode.encode(pass),'PBKDF2',false,['deriveKey']);return crypto.subtle.deriveKey({name:'PBKDF2',salt,iterations,hash:'SHA-256'},base,{name:'AES-GCM',length:256},false,['encrypt','decrypt']);}
 async encrypt(value,id){if(!this.key)throw new Error('V3_VAULT_LOCKED');const iv=crypto.getRandomValues(new Uint8Array(12));const encrypted=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:encode.encode(this.prefix+'|'+id)},this.key,encode.encode(JSON.stringify(value)));return {id:this.prefix+'|'+id,owner:this.prefix,iv:b64(iv),cipher:b64(encrypted)};}
 async decrypt(row,id){if(!this.key)throw new Error('V3_VAULT_LOCKED');try{return JSON.parse(decode.decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:bytes(row.iv),additionalData:encode.encode(this.prefix+'|'+id)},this.key,bytes(row.cipher))));}catch{throw new Error('V3_VAULT_WRONG_KEY');}}
 async unlock(pass){if(typeof pass!=='string'||pass.length<12||pass.length>256)throw new Error('V3_VAULT_WRONG_KEY');let record=await this.get('keys',this.prefix);
  if(record){this.key=await this.derive(pass,bytes(record.salt));try{await this.decrypt(record.check,'check');}catch(e){this.key=null;throw e;}}
  else{const salt=crypto.getRandomValues(new Uint8Array(16));this.key=await this.derive(pass,salt);record={id:this.prefix,salt:b64(salt),iterations,version:1,check:await this.encrypt({ok:true},'check')};await this.put('keys',record);}return this;
 }
 lock(){this.key=null;}
 async write(id,value){return this.put('entries',await this.encrypt(value,id));}
 async read(id){const r=await this.get('entries',this.prefix+'|'+id);return r?this.decrypt(r,id):null;}
 async add(event){const id='response:'+event.id,old=await this.read(id);if(old){if(canonical(old.event)!==canonical(event))throw new Error('V3_IDEMPOTENCY_CONFLICT');return old;}const value={event,status:'pending',attempts:0,created_at:new Date().toISOString()};await this.write(id,value);return value;}
 async entries(){const rows=await request(this.db.transaction('entries').objectStore('entries').getAll());const own=rows.filter(x=>x.owner===this.prefix&&x.id.startsWith(this.prefix+'|response:'));const decoded=[];for(const row of own)decoded.push(await this.decrypt(row,row.id.slice(this.prefix.length+1)));return decoded.sort((a,b)=>a.event.captured_at.localeCompare(b.event.captured_at));}
 async acknowledge(event,receipt){assertReceipt(event,receipt);const old=await this.read('response:'+event.id);if(!old||canonical(old.event)!==canonical(event))throw new Error('V3_IDEMPOTENCY_CONFLICT');await this.write('response:'+event.id,{...old,status:'received',receipt});}
 async failure(event,error){const old=await this.read('response:'+event.id);if(!old)return;await this.write('response:'+event.id,{...old,attempts:old.attempts+1,error:String(error?.message||'V3_NETWORK').match(/V3_[A-Z0-9_]+/)?.[0]||'RED-01',status:'pending',blocked:!!error?.code&&/^(42501|23514|22|P0001)/.test(error.code)});}
 async exportEncrypted(){const rows=await request(this.db.transaction('entries').objectStore('entries').getAll());return {format:'PULSO_V3_ENCRYPTED_RESCUE',version:1,owner:this.prefix,environment_hash:await digest(this.environment),key:await this.get('keys',this.prefix),entries:rows.filter(x=>x.owner===this.prefix),created_at:new Date().toISOString(),warning:'NO ES UN RESPALDO DEL SERVIDOR. Requiere la frase local y la misma identidad.'};}
 async importEncrypted(data,pass){if(!data||data.format!=='PULSO_V3_ENCRYPTED_RESCUE'||data.version!==1||data.owner!==this.prefix||data.environment_hash!==await digest(this.environment)||data.entries.length>100000||data.key.iterations!==iterations||data.key.id!==this.prefix)throw new Error('V3_INVALID_RESCUE');
  // Validate ALL decrypted records before changing the current vault. New device may use another local passphrase.
  const currentKey=this.key,foreignKey=await this.derive(pass,bytes(data.key.salt));const decoded=[];
  try{this.key=foreignKey;await this.decrypt(data.key.check,'check');for(const entry of data.entries){if(entry.owner!==this.prefix||!entry.id.startsWith(this.prefix+'|'))throw new Error('V3_INVALID_RESCUE');const id=entry.id.slice(this.prefix.length+1);if(id.startsWith('response:')){const value=await this.decrypt(entry,id);if(id!=='response:'+value.event.id)throw new Error('V3_INVALID_RESCUE');decoded.push(value);}}}finally{this.key=currentKey;}
  if(!this.key)throw new Error('V3_VAULT_LOCKED');
  for(const value of decoded){const old=await this.read('response:'+value.event.id);if(old&&canonical(old.event)!==canonical(value.event))throw new Error('V3_IDEMPOTENCY_CONFLICT');}
  for(const value of decoded){const old=await this.read('response:'+value.event.id);if(!old)await this.write('response:'+value.event.id,{...value,status:'pending',receipt:undefined});}
  return {imported:decoded.length,needs_server_readback:true};
 }
}
export async function legacyPending(){try{if(!indexedDB.databases)return {unknown:true};const names=await indexedDB.databases();if(!names.some(x=>x.name==='pulso-anonymous-v2'))return {count:0};const d=await request(indexedDB.open('pulso-anonymous-v2'));if(!d.objectStoreNames.contains('outbox')){d.close();return {count:0};}const count=await request(d.transaction('outbox').objectStore('outbox').count());d.close();return {count};}catch{return {unknown:true};}}
