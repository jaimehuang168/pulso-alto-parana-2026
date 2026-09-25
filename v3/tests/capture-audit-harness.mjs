/** LOCALHOST TEST BUILD ONLY: actual simulation SQL, added latency/response-loss instrumentation. */
import {createSimulation as original} from '../web/simulation.mjs';
export async function createSimulation(){
 if(!['127.0.0.1','localhost'].includes(location.hostname))throw new Error('QA_LOCALHOST_ONLY');
 const api=await original(),rpc=api.rpc;
 const qa={api,submissions:[],dropNextReceipt:false,delay:100};
 api.rpc=async(name,args={})=>{
  if(name==='v3_submit_response'){
   qa.submissions.push(structuredClone(args.p_event));
   await new Promise(r=>setTimeout(r,qa.delay));
   const result=await rpc(name,args);
   if(qa.dropNextReceipt){qa.dropNextReceipt=false;throw new TypeError('Failed to fetch');}
   return result;
  }
  return rpc(name,args);
 };
 window.__captureAudit=qa;return api;
}
