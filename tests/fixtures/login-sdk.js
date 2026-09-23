// 隔離瀏覽器測試用；替代 SDK，絕不呼叫 Supabase 或真實帳號。
(()=>{
 const session={user:{id:'qa-browser-user',email:'view-qa001@pulso-encuestadores.invalid'},expires_at:Math.floor(Date.now()/1000)+3600,access_token:'NOT_A_REAL_TOKEN'};
 window.qaLogin={scenario:window.qaScenario||'disabled',session:!!window.qaSession,calls:[],writes:0};const q=window.qaLogin;
 const failures={wrong:{code:'invalid_credentials',status:400,message:'Invalid login credentials'},network:{name:'AuthRetryableFetchError',message:'Failed to fetch'},unconfirmed:{code:'email_not_confirmed',message:'Email not confirmed'},rate:{status:429,message:'Too many requests'}};
 const client={
  auth:{getSession:async()=>({data:{session:q.session?session:null},error:null}),signInWithPassword:async()=>{await new Promise(r=>setTimeout(r,40));const e=failures[q.scenario];if(e)return{data:{session:null},error:e};q.session=true;return{data:{session,user:session.user},error:null};},signOut:async()=>{q.session=false;return{error:null};},getUser:async()=>({data:{user:session.user},error:null})},
  rpc(name){q.calls.push(name);let response;if(!['bootstrap','ping'].includes(name)){q.writes++;response={data:null,error:{code:'42501',message:'Unexpected test RPC'}};}
   else if(name==='ping')response={data:null,error:null};
   else if(q.scenario!=='active')response={data:null,error:{code:'42501',message:'Cuenta no habilitada o sin perfil asignado.'}};
   else response={error:null,data:{profile:{id:session.user.id,code:'VIEW-QA001',role:'viewer',district_id:'cde',active:true},settings:{id:1,state:'setup',viewer_enabled:false},districts:[{id:'cde',name:'Ciudad del Este'}],candidates:[],stations:[]}};
   const result=Promise.resolve(response);result.abortSignal=()=>result;return result;
  },
  channel(){const channel={on:()=>channel,subscribe:fn=>{fn('SUBSCRIBED');return channel;}};return channel;},removeChannel:async()=>{},functions:{invoke:async()=>{q.writes++;throw new Error('No test writes allowed');}}
 };window.supabase={createClient:()=>client};
})();
