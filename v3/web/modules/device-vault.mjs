/** Own-phone mode. Automatic encryption relies on the unlocked phone and same-origin security. */
import {Vault} from './vault.mjs';
import {digest,token,canonical} from './core.mjs';
const b64=a=>btoa(String.fromCharCode(...new Uint8Array(a)));
const all=db=>new Promise((resolve,reject)=>{const r=db.transaction('entries').objectStore('entries').getAll();r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});
export class DeviceVault extends Vault{
 constructor(...args){super(...args);this.automatic=true;this.legacy=null;}
 async open(){
  this.prefix=await digest(this.environment+'|'+this.user);
  this.db=await new Promise((resolve,reject)=>{const r=indexedDB.open('pulso-personal-device-v1',1);
   r.onupgradeneeded=()=>{for(const n of ['keys','entries'])r.result.createObjectStore(n,{keyPath:'id'});};
   r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error||Error('V3_STORAGE_FAILED'));});
  this.db.onversionchange=()=>this.db.close();
  this.legacy=new Vault(this.environment,this.user);await this.legacy.open();return this;
 }
 async legacyDigest(){
  if(!await this.legacy.exists())return null;
  const key=await this.legacy.get('keys',this.prefix);
  const rows=(await all(this.legacy.db)).filter(x=>x.owner===this.prefix).sort((a,b)=>a.id.localeCompare(b.id));
  return digest(canonical({key,rows}));
 }
 async loadDeviceKey(allowCreate){
  let record=await this.get('keys',this.prefix);
  if(!record){
   if(!allowCreate)throw Error('V3_NO_LOCAL_ARCHIVE');
   const key=await crypto.subtle.generateKey({name:'AES-GCM',length:256},false,['encrypt','decrypt']);
   await new Promise((resolve,reject)=>{
    const t=this.db.transaction('keys','readwrite'),s=t.objectStore('keys'),r=s.get(this.prefix);
    r.onsuccess=()=>{if(!r.result)s.add({id:this.prefix,version:2,mode:'device',cryptoKey:key});};
    t.oncomplete=resolve;t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error||Error('V3_STORAGE_FAILED'));
   });
   record=await this.get('keys',this.prefix);
  }
  if(record?.version!==2||record.mode!=='device'||!record.cryptoKey||record.cryptoKey.extractable
   ||record.cryptoKey.algorithm?.name!=='AES-GCM'||record.cryptoKey.algorithm.length!==256)throw Error('V3_DEVICE_STORAGE_UNAVAILABLE');
  this.key=record.cryptoKey;
  const probe=await this.encrypt({ok:true},'probe');if(!(await this.decrypt(probe,'probe')).ok)throw Error('V3_DEVICE_STORAGE_UNAVAILABLE');
  return record;
 }
 async automaticUnlock(allowCreate=false){
  const record=await this.get('keys',this.prefix),source=await this.legacyDigest();
  if(source&&source!==record?.legacy_digest){this.key=null;return false;}
  await this.loadDeviceKey(allowCreate);return true;
 }
 async migrateLegacy(pass){
  // Copy; do not replace keys, overwrite, delete, or mutate any previous archive.
  const before=await this.legacyDigest();if(!before)throw Error('V3_NO_LOCAL_ARCHIVE');
  await this.legacy.unlock(pass);const source=(await all(this.legacy.db)).filter(x=>x.owner===this.prefix),decoded=[];
  try{for(const row of source){const id=row.id.slice(this.prefix.length+1);decoded.push([id,await this.legacy.decrypt(row,id)]);}}
  finally{this.legacy.lock();}
  await this.loadDeviceKey(true);
  const existing=(await all(this.db)).filter(x=>x.owner===this.prefix),newRows=[];
  for(const[id,value]of decoded){
   const old=await this.read(id);
   if(id.startsWith('response:')&&old){if(canonical(old.event)!==canonical(value.event))throw Error('V3_IDEMPOTENCY_CONFLICT');continue;}
   if(old!==null)continue;
   newRows.push(await this.encrypt(value,id));
  }
  if(await this.legacyDigest()!==before)throw Error('V3_RELOAD_REQUIRED');
  await new Promise((resolve,reject)=>{
   const t=this.db.transaction(['keys','entries'],'readwrite'),entries=t.objectStore('entries');let failure;
   const r=entries.getAll();r.onsuccess=()=>{
    const current=r.result.filter(x=>x.owner===this.prefix);
    if(canonical(current.sort((a,b)=>a.id.localeCompare(b.id)))!==canonical(existing.sort((a,b)=>a.id.localeCompare(b.id)))){failure=Error('V3_RELOAD_REQUIRED');t.abort();return;}
    for(const row of newRows)entries.add(row);
    const k=t.objectStore('keys').get(this.prefix);k.onsuccess=()=>{if(!k.result){failure=Error('V3_STORAGE_FAILED');t.abort();return;}t.objectStore('keys').put({...k.result,legacy_digest:before});};
   };
   t.oncomplete=resolve;t.onerror=()=>reject(failure||t.error);t.onabort=()=>reject(failure||t.error||Error('V3_STORAGE_FAILED'));
  });
  return {copied:newRows.length,legacy_preserved:true};
 }
 async portableBackup(){
  if(!this.key)throw Error('V3_VAULT_LOCKED');
  const phrase=token(),salt=crypto.getRandomValues(new Uint8Array(16));
  const rows=await all(this.db),decoded=[];
  for(const row of rows.filter(x=>x.owner===this.prefix))decoded.push([row.id.slice(this.prefix.length+1),await this.decrypt(row,row.id.slice(this.prefix.length+1))]);
  try{
   const writer=new Vault(this.environment,this.user);writer.prefix=this.prefix;writer.key=await this.derive(phrase,salt);
   const key={id:this.prefix,salt:b64(salt),iterations:310000,version:1,check:await writer.encrypt({ok:true},'check')};
   const entries=[];for(const[id,value]of decoded)entries.push(await writer.encrypt(value,id));
   return {phrase,data:{format:'PULSO_V3_ENCRYPTED_RESCUE',version:1,owner:this.prefix,environment_hash:await digest(this.environment),key,entries,
    created_at:new Date().toISOString(),warning:'Copia cifrada. Conserve por separado la clave de recuperación. No es un recibo del servidor.'}};
  }finally{/* The active device key is never replaced during backup. */}
 }
 async exportEncrypted(){throw Error('V3_USE_PORTABLE_BACKUP');}
 lock(){super.lock();this.legacy?.lock();}
}
