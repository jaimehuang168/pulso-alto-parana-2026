import {CLIENT,uuid} from './core.mjs';
export class CloudAPI{
 constructor(config){this.config=config;this.sb=null;this.channel=null;}
 async client(){if(this.sb)return this.sb;const c=this.config;if(!c?.supabaseUrl||!c?.publishableKey)throw new Error('V3_CONNECTION_NOT_CONFIGURED');const u=new URL(c.supabaseUrl);if(u.protocol!=='https:'&& !['localhost','127.0.0.1'].includes(u.hostname))throw new Error('V3_CONNECTION_NOT_CONFIGURED');if(c.publishableKey.startsWith('sb_secret_'))throw new Error('V3_PUBLIC_KEY_REQUIRED');if(!window.supabase)throw new Error('V3_SDK_NOT_LOADED');this.sb=window.supabase.createClient(c.supabaseUrl,c.publishableKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false,storageKey:'pulso-v3-auth:'+u.host}});return this.sb;}
 async session(){return (await(await this.client()).auth.getSession()).data.session;}
 async login(code,password){const email=code.includes('@')?code.trim():code.trim().toLowerCase()+'@pulso-encuestadores.invalid';const {data,error}=await(await this.client()).auth.signInWithPassword({email,password});if(error)throw error;return data.session;}
 async logout(){const sb=await this.client();if(this.channel)await sb.removeChannel(this.channel);this.channel=null;const {error}=await sb.auth.signOut({scope:'local'});if(error)throw error;}
 async rpc(name,args={}){if(!/^v3_[a-z_]+$/.test(name))throw new Error('V3_UNKNOWN_RPC');const {data,error}=await(await this.client()).rpc(name,args).abortSignal(AbortSignal.timeout(20000));if(error)throw error;return data;}
 async command(action,data,expected=0,request=uuid()){return this.rpc('v3_command',{p_action:action,p_data:data,p_expected:expected,p_request_id:request,p_client:CLIENT});}
 async edge(body,anonymous=false){let headers={'Content-Type':'application/json',apikey:this.config.publishableKey};if(!anonymous){let session=await this.session();if(session?.expires_at*1000<Date.now()+60000){const refreshed=await(await this.client()).auth.refreshSession();if(refreshed.error)throw refreshed.error;session=refreshed.data.session;}if(!session?.access_token)throw new Error('V3_SESSION_REQUIRED');headers.Authorization='Bearer '+session.access_token;}
  const r=await fetch(this.config.supabaseUrl+'/functions/v1/field-enrollment',{method:'POST',headers,body:JSON.stringify(body),cache:'no-store',referrerPolicy:'no-referrer',signal:AbortSignal.timeout(45000)});let result;try{result=await r.json();}catch{throw new Error('V3_SERVER_INVALID_RESPONSE');}if(!r.ok||result.error)throw Object.assign(new Error(result.error||'V3_SERVER_ERROR'),{status:r.status,reference:result.reference});return result;
 }
 async claim(token,claimSecret,lockId){const r=await this.edge({action:'claim',token,claim_secret:claimSecret,lock_id:lockId},true);const {data,error}=await(await this.client()).auth.verifyOtp({token_hash:r.token_hash,type:'email'});if(error)throw error;await this.rpc('v3_enrollment_complete',{p_enrollment:r.enrollment_id});return data.session;}
 async changePassword(password){if(password.length<16)throw new Error('V3_PASSWORD_TOO_SHORT');const {error}=await(await this.client()).auth.updateUser({password});if(error)throw error;}
 async connect(callback){
  const sb=await this.client(),session=await this.session();if(!session?.access_token)return;
  if(this.channel)await sb.removeChannel(this.channel);await sb.realtime.setAuth(session.access_token);
  // A connected socket is not proof that a particular change was received.
  // Refresh the authorized snapshot on reconnect; app polling also covers the setup gap.
  this.channel=sb.channel('pulso-v3-signals').on('postgres_changes',{event:'UPDATE',schema:'public',table:'v3_signals'},callback).subscribe(status=>{if(status==='SUBSCRIBED')callback();});
 }
 async attachmentUpload(path,file){const {data,error}=await(await this.client()).storage.from('pulso-v3-docs').upload(path,file,{upsert:false,contentType:file.type,cacheControl:'0'});if(error)throw error;return data;}
 async attachmentURL(path){const {data,error}=await(await this.client()).storage.from('pulso-v3-docs').createSignedUrl(path,60);if(error)throw error;return data.signedUrl;}
}
