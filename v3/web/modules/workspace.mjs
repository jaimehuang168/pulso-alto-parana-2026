/** Identity-only presentation wrapper. Existing work areas and calculations are unchanged. */
export * from './workspace-base.mjs';
import {shell as layout} from './workspace-base.mjs';
import {sessionIdentity} from './session-identity.mjs';
const styles=`<style>
.current-session{display:flex;gap:10px;align-items:center;min-width:0;max-width:320px;color:#163c44;text-align:left}.current-session>div{min-width:0;display:grid;gap:2px}.current-session small{font-size:11px;line-height:1.4;color:#5b737b}.current-session strong{display:block;font-size:17px;line-height:1.35;overflow-wrap:anywhere}.current-session [data-session-code]{font-size:12px;line-height:1.4;color:#526e76;overflow-wrap:anywhere}.session-avatar{width:36px;height:36px;display:grid;place-items:center;border-radius:50%;background:#e0efe9;color:#176b5d;font-size:18px;font-weight:700;flex:none}.workspace .topbar{gap:16px;flex-wrap:wrap}.workspace .topbar .desktoplabel{flex:1;min-width:120px;font-size:14px}.workspace .topbar .actions{flex-wrap:wrap}
@media(max-width:1100px){.workspace .topbar .desktoplabel{display:none}.workspace .topbar .current-session{flex:1}.workspace .topbar .actions{margin-left:auto}}
@media(max-width:760px){.workspace .topbar{gap:10px}.workspace .topbar .current-session{order:3;flex:1 0 100%;max-width:none;padding:10px 0 2px;border-top:1px solid #d9e6e7}.workspace .topbar .actions{gap:6px}.workspace .topbar .actions button{min-height:44px}.workspace .topbar .actions .badge{display:none}}
@media print{.current-session{display:none!important}}
</style>`;
export function shell(S,body,helpers){
 let html=layout(S,body,helpers);
 const anchor='<div class="actions"><span class="badge ';
 if(html.split(anchor).length!==2)throw new Error('Session header template mismatch');
 html=html.replace(/<div class="identity">[\s\S]*?<\/div>/,'');
 return styles+html.replace(anchor,sessionIdentity(S.boot.actor,S.offline)+anchor);
}
