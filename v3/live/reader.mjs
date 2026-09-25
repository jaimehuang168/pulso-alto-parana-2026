import {validate} from './core.mjs';
/** Single-flight polls, bounded authorization validity and late-response fencing. */
export class LiveReader{
 constructor(fetcher,onData,onState,{now=()=>performance.now(),interval=5000}={}){Object.assign(this,{fetcher,onData,onState,now,interval});this.epoch=0;this.paused=false;this.lastSuccess=null;this.timer=null;this.controller=null;this.audience='auto';this.busy=false;this.validFor=15;}
 change(audience){this.epoch++;this.controller?.abort();clearTimeout(this.timer);this.busy=false;this.audience=audience;this.lastSuccess=null;this.onData(null);return this.refresh();}
 async refresh(){if(this.busy)return;clearTimeout(this.timer);this.busy=true;const requestedAt=this.now(),epoch=this.epoch,mode=this.audience,ctrl=new AbortController();this.controller=ctrl;this.onState('loading');const timeout=setTimeout(()=>ctrl.abort(),10000);
  try{const value=validate(await this.fetcher(mode,ctrl.signal),mode);if(epoch!==this.epoch)return;this.lastSuccess=requestedAt;this.validFor=(Date.parse(value.valid_until)-Date.parse(value.server_time))/1000;if(value.audience==='released'&&this.age()>=this.validFor){this.onData(null);this.onState('stale');return;}this.onData(value);this.onState(this.paused?'paused':'live');}
  catch(e){if(epoch!==this.epoch)return;const raw=String(e?.message||'');const denied=e?.status===401||e?.status===403||/42501|SCOPE_DENIED|ADMIN_ONLY|ACCOUNT_DISABLED|SESSION_REQUIRED|VIEWER_RESULTS_PENDING|PGRST202|MIGRATION_REQUIRED/.test(raw+String(e?.code||''));if(denied){this.onData(null);this.lastSuccess=null;}this.onState(denied?'denied':'offline',e);}
  finally{clearTimeout(timeout);if(epoch===this.epoch){this.busy=false;if(!this.paused)this.timer=setTimeout(()=>this.refresh(),this.interval);}}
 }
 pause(value){this.paused=value;clearTimeout(this.timer);if(value){this.epoch++;this.controller?.abort();this.busy=false;this.onState('paused');}else return this.refresh();}
 age(){return this.lastSuccess===null?Infinity:(this.now()-this.lastSuccess)/1000;}
 stop(){this.paused=true;this.epoch++;clearTimeout(this.timer);this.controller?.abort();this.busy=false;}
}
