/** 繁體中文部署接續工具。只使用公開連線參數，不讀取或儲存後端秘密。 */
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {createInterface} from 'node:readline/promises';
import process from 'node:process';

export const REPO='jaimehuang168/pulso-alto-parana-2026';
export function validateUrl(value){
  const text=String(value||'').trim();
  if(!/^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/.test(text))throw new Error('Project URL 格式不正確；只接受 https://專案代碼.supabase.co。');
  return new URL(text).origin;
}
export function validatePublishableKey(value){
  const key=String(value||'').trim();
  if(!/^sb_publishable_[A-Za-z0-9_-]{10,}$/.test(key))throw new Error('這裡只接受 sb_publishable_ 開頭的公開金鑰；不能使用 Secret key、service_role 或密碼。');
  return key;
}
export function ensureSameBackend(previous,next){
  if(previous&&validateUrl(previous)!==validateUrl(next))throw new Error('目前 repository 已指向不同資料庫。已停止；請先核對待傳資料、帳號與環境，不自動切換後端。');
}
export function selectRun(runs,sha,started){
  return runs.find(r=>r.event==='workflow_dispatch'&&r.headSha===sha&&Date.parse(r.createdAt)>=started-5000);
}
function command(args,{inherit=false,allowFailure=false}={}){
  const result=spawnSync('gh',args,{encoding:'utf8',stdio:inherit?'inherit':'pipe',shell:false});
  if(result.error)throw new Error('找不到 GitHub CLI（gh）。請安裝後重新開啟終端機。');
  if(result.status!==0&&!allowFailure)throw new Error('GitHub 操作未完成。請確認登入、權限或 GitHub 畫面中的錯誤；程式未強制覆蓋任何資料。');
  return {ok:result.status===0,text:result.stdout||'',error:result.stderr||''};
}
function api(endpoint,args=[],allowFailure=false){
  const r=command(['api',endpoint,...args],{allowFailure});
  return {...r,data:r.ok&&r.text.trim()?JSON.parse(r.text):null};
}
function variable(name){
  const r=api(`repos/${REPO}/actions/variables/${name}`,[],true);
  if(!r.ok&&!/404/.test(r.error))throw new Error('無法讀取 repository variables；請確認登入帳號對此 repository 有管理權限。');
  return r.ok?r.data.value:'';
}
async function main(){
  const args=process.argv.slice(2);
  if(args.some(a=>!['--check','--publish'].includes(a))||args.length>1)throw new Error('用法：node scripts/continue-deploy-zh.mjs --check 或 --publish');
  const publish=args.includes('--publish');
  const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
  for(const f of ['web/app.js','web/core.js','supabase/00_INSTALL_NEW_PROJECT.sql','.github/workflows/pages.yml']){
    if(!fs.existsSync(path.join(root,f)))throw new Error(`缺少 ${f}。請使用完整專案資料夾，不要只執行單一 HTML。`);
  }
  console.log(`\nPulso 部署接續｜${publish?'準備發布':'唯讀檢查'}\n目標：${REPO}\n`);
  const auth=command(['auth','status'],{allowFailure:true});
  if(!auth.ok){
    if(!publish)throw new Error('尚未登入 GitHub。先執行 gh auth login --web --git-protocol https --scopes repo,workflow');
    console.log('接下來由 GitHub CLI 開啟瀏覽器授權；不要將 token 傳給任何人。');
    command(['auth','login','--web','--git-protocol','https','--scopes','repo,workflow'],{inherit:true});
  }
  const user=api('user').data;
  const repository=api(`repos/${REPO}`).data;
  console.log(`登入帳號：${user.login}`);
  if(!repository.permissions?.admin)throw new Error('此工具需要管理此 repository 的權限；不會要求或修改全域插件權限。');
  const branch=repository.default_branch;
  const source=api(`repos/${REPO}/contents/web/app.js?ref=${encodeURIComponent(branch)}`,[],true);
  if(!source.ok)throw new Error('GitHub 尚未收到完整原始碼。請先檢查原始碼匯入工作流程；不要重新建立同名 repository。');
  console.log('原始碼：GitHub 已有 web/app.js（不是雲端功能驗收）。');
  const previousUrl=variable('SUPABASE_URL');
  const previousKey=variable('SUPABASE_PUBLISHABLE_KEY');
  let pages=api(`repos/${REPO}/pages`,[],true);
  if(!pages.ok&&!/404/.test(pages.error))throw new Error('無法讀取 Pages 狀態；請在 GitHub 檢查 Pages 管理權限。');
  console.log(`GitHub Pages：${pages.ok?`已設定（${pages.data.build_type}）`:'尚未設定'}`);
  console.log(`Project URL：${previousUrl?'已設定':'尚未設定'}；Publishable key：${previousKey?'已設定':'尚未設定'}`);
  if(!publish){
    if(previousUrl)validateUrl(previousUrl);
    if(previousKey)validatePublishableKey(previousKey);
    console.log('\n檢查結束，未更動設定。後端 SQL、管理者帳號、Edge Function 與實機驗收狀態不在此檢查範圍。');
    console.log('準備完成後執行：node scripts/continue-deploy-zh.mjs --publish');
    return;
  }
  const rl=createInterface({input:process.stdin,output:process.stdout});
  let url,key;
  try{
    url=validateUrl(previousUrl||(await rl.question('請貼上 Supabase Project URL（不是 Dashboard 網址）：')));
    key=validatePublishableKey(previousKey||(await rl.question('請貼上公開 Publishable key（sb_publishable_...；不要貼 Secret key）：')));
    ensureSameBackend(previousUrl,url);
    console.log(`\n即將使用既有 repository：${REPO}\n後端：${url}`);
    console.log('只設定公開連線參數、啟用 Pages 並執行網站建置；不建立資料庫、不建立 60 個帳號，也不開放正式收件。');
    const answer=await rl.question('確認發布請輸入 PUBLISH；其他輸入均取消：');
    if(answer!=='PUBLISH'){console.log('已取消，未更動設定。');return;}
  }finally{rl.close();}
  // 在任何寫入之前確認提供的公開金鑰可連到該專案；不查詢投票資料。
  let response;
  try{response=await fetch(`${url}/auth/v1/settings`,{headers:{apikey:key},signal:AbortSignal.timeout(15000)});}catch{throw new Error('無法連接 Supabase。請檢查網址、網路或專案是否暫停；尚未寫入 GitHub 設定。');}
  if(!response.ok)throw new Error(`Supabase 公開連線驗證未通過（HTTP ${response.status}）；請核對同一個專案的 URL 與 Publishable key。`);
  const settings=await response.json();
  if(settings.disable_signup!==true)throw new Error('Supabase 仍允許公眾自行註冊，或無法確認此限制。請先在 Authentication 設定停用 Allow new users to sign up，再重試。');
  if(settings.external?.anonymous_users===true)throw new Error('請先停用 Supabase 的匿名登入，再重試。');
  console.log('Auth 連線與關閉公開註冊檢查通過；這不是資料庫權限或 Edge Function 驗收。');
  if(!previousUrl)command(['variable','set','SUPABASE_URL','--repo',REPO,'--body',url]);
  if(!previousKey)command(['variable','set','SUPABASE_PUBLISHABLE_KEY','--repo',REPO,'--body',key]);
  if(!pages.ok){
    pages=api(`repos/${REPO}/pages`,['--method','POST','-f','build_type=workflow'],true);
    if(!pages.ok)throw new Error('Pages 未能自動啟用。請至 repository → Settings → Pages → Source 選 GitHub Actions，再執行本工具；已存在的連線設定會保留。');
  }else if(pages.data.build_type!=='workflow'){
    throw new Error('Pages 目前不是 GitHub Actions 來源。工具不會覆蓋既有發布方式；請在 Settings → Pages 手動核對並選 GitHub Actions。');
  }
  const sha=api(`repos/${REPO}/git/ref/heads/${encodeURIComponent(branch)}`).data.object.sha;
  const started=Date.now();
  command(['workflow','run','pages.yml','--repo',REPO,'--ref',branch],{inherit:true});
  let selected;
  for(let attempt=0;attempt<5;attempt++){
    await new Promise(resolve=>setTimeout(resolve,3000));
    const runs=JSON.parse(command(['run','list','--repo',REPO,'--workflow','pages.yml','--event','workflow_dispatch','--limit','10','--json','databaseId,headSha,event,createdAt']).text);
    selected=selectRun(runs,sha,started);if(selected)break;
  }
  if(!selected)throw new Error('已送出工作流程，但尚未找到對應執行紀錄。請到 GitHub Actions 檢查；不要因此刪除 repository。');
  command(['run','watch',String(selected.databaseId),'--repo',REPO,'--exit-status'],{inherit:true});
  const actual=api(`repos/${REPO}/pages`).data.html_url;
  console.log(`\nGitHub 前端建置／部署工作流程通過。GitHub 回報網址：${actual}`);
  console.log('尚須用管理者登入、兩支真實手機對帳及 60 帳號負載測試，才能驗收多人調查。');
}
const direct=process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url);
if(direct)main().catch(error=>{console.error(`\n停止：${error.message}\n未宣告正式上線；已成功的步驟不必刪除重做。`);process.exitCode=1;});
