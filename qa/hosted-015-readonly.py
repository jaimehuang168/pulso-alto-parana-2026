"""Bounded public-endpoint probe. No account/session creation or questionnaire writes."""
import base64, datetime, hashlib, json, pathlib, re, time
import urllib.error, urllib.parse, urllib.request
BASE='https://jaimehuang168.github.io/pulso-alto-parana-2026/'
ORIGIN='https://jaimehuang168.github.io'
SOURCE='85c45327e3aa34766eacbf7c06095389d5c62d03'
OUT=pathlib.Path('evidence');OUT.mkdir(exist_ok=True)
checks=[]
def request(url,method='GET',headers=None,body=None):
    started=time.monotonic()
    req=urllib.request.Request(url,data=body,method=method,headers={'User-Agent':'Pulso-ReadOnly-Deployment-Check/1','Cache-Control':'no-cache',**(headers or {})})
    try:
        with urllib.request.urlopen(req,timeout=25) as r:
            return r.status,dict(r.headers),r.read(8000000),round((time.monotonic()-started)*1000)
    except urllib.error.HTTPError as e:
        return e.code,dict(e.headers),e.read(10000),round((time.monotonic()-started)*1000)
    except Exception as e:
        return 0,{},type(e).__name__.encode(),round((time.monotonic()-started)*1000)
def js(raw):
    try:return json.loads(raw)
    except (ValueError,UnicodeError):return {}
def check(name,ok,details):
    row={'name':name,'status':'pass' if ok else 'fail','details':details};checks.append(row)
    print(json.dumps(row,ensure_ascii=False))
def lower(headers):return {k.lower():v for k,v in headers.items()}
release=None
try:
    status,_,raw,elapsed=request(BASE+'company-release.json')
    release=js(raw)
    check('published_release_matches_main',status==200 and release.get('source_commit')==SOURCE and release.get('edition')=='personal-phone-015',{'http':status,'source_commit':release.get('source_commit'),'edition':release.get('edition'),'duration_ms':elapsed})
    for path,digest in release.get('files',{}).items():
        assert re.fullmatch(r'[A-Za-z0-9_./-]+',path) and '..' not in path and not path.startswith('/')
        s,_,data,ms=request(BASE+path)
        check('published_sha256:'+path,s==200 and hashlib.sha256(data).hexdigest()==digest,{'http':s,'duration_ms':ms})
    s,_,data,ms=request(BASE+'v3/config.js')
    match=re.fullmatch(r'\s*window\.PULSO_V3_CONFIG\s*=\s*(\{.*\})\s*;?\s*',data.decode(),re.S)
    config=json.loads(match[1]) if match else {}
    url=config.get('supabaseUrl','').rstrip('/');key=config.get('publishableKey','')
    safe=bool(re.fullmatch(r'https://[a-z0-9]+\.supabase\.co',url)) and config.get('simulation') is False
    if key.startswith('eyJ'):
        try:
            part=key.split('.')[1];role=json.loads(base64.urlsafe_b64decode(part+'='*(-len(part)%4))).get('role')
        except Exception:role=None
        safe=safe and role=='anon'
    else:safe=safe and key.startswith('sb_publishable_')
    check('configured_real_frontend',s==200 and safe,{'http':s,'simulation':config.get('simulation'),'environment':config.get('environment'),'public_key_not_exported':True})
    if not safe:raise RuntimeError('Refuse unknown destination or privileged API key')
    print('::add-mask::'+key)
    edge=url+'/functions/v1/interviewer-access'
    s,h,b,ms=request(edge,'OPTIONS',{'Origin':ORIGIN,'Access-Control-Request-Method':'POST','Access-Control-Request-Headers':'authorization,apikey,content-type'})
    h=lower(h);allow={v.strip().lower() for v in h.get('access-control-allow-headers','').split(',')}
    check('interviewer_access_cors',s==204 and h.get('access-control-allow-origin')==ORIGIN and 'POST' in h.get('access-control-allow-methods','') and {'authorization','apikey','content-type'}<=allow,{'http':s,'allow_origin':h.get('access-control-allow-origin'),'error':js(b).get('error') or js(b).get('message'),'duration_ms':ms})
    s,h,b,ms=request(edge,'POST',{'Origin':ORIGIN,'apikey':key,'Content-Type':'application/json'},b'{}')
    e=js(b);h=lower(h)
    check('interviewer_access_unsigned_denied_by_app',s==401 and e.get('error')=='V3_SESSION_REQUIRED' and h.get('access-control-allow-origin')==ORIGIN,{'http':s,'error':e.get('error') or e.get('message'),'reference':e.get('reference'),'duration_ms':ms})
    s,h,b,ms=request(edge,'POST',{'Origin':'https://untrusted.invalid','apikey':key,'Content-Type':'application/json'},b'{}')
    e=js(b);h=lower(h)
    check('interviewer_access_unapproved_origin_denied',s==403 and e.get('error')=='V3_ORIGIN_DENIED' and not h.get('access-control-allow-origin'),{'http':s,'error':e.get('error') or e.get('message'),'duration_ms':ms})
    headers={'apikey':key,'Origin':ORIGIN,'Accept':'application/json'}
    if key.startswith('eyJ'):headers['Authorization']='Bearer '+key
    # GET only for RPC: PostgREST runs read-only transactions; these roles must be denied.
    probes=[('v3_simple_account_service',{'p_step':'diagnostic_readonly_noop','p_data':'{}'}),('v3_prepare_interviewer',{'p_device':'00000000-0000-4000-8000-000000000001','p_client':'30000'}),('v3_installation_status',{})]
    for fn,args in probes:
        endpoint=url+'/rest/v1/rpc/'+fn+('?' + urllib.parse.urlencode(args) if args else '')
        s,h,b,ms=request(endpoint,headers=headers);e=js(b)
        check('anonymous_rpc_denied:'+fn,s in [401,403] and e.get('code')=='42501',{'http':s,'code':e.get('code'),'message':str(e.get('message',''))[:220],'duration_ms':ms})
except Exception as e:
    check('probe_execution',False,{'error_type':type(e).__name__,'message':str(e)[:160]})
finally:
    result={'schema':'pulso-hosted-readonly-check-1','checked_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Live published static files and unauthenticated endpoint boundaries only. No privileged API keys, real sessions, account creation, survey writes or operational changes. HTTP access logs may be recorded by the provider.','source_commit':SOURCE,'pass':bool(checks) and all(x['status']=='pass' for x in checks),'passed':sum(x['status']=='pass' for x in checks),'failed':sum(x['status']=='fail' for x in checks),'checks':checks,'not_tested':['authenticated_admin_create_account','new_interviewer_login','real_device_offline_sync','current_database_mode_via_authenticated_session'],'account_creation_attempted':False,'survey_write_attempted':False,'database_mutation_attempted':False}
    (OUT/'hosted-readonly-check.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print('SUMMARY '+json.dumps({k:result[k] for k in ['pass','passed','failed','checked_at_utc']}))
    raise SystemExit(0 if result['pass'] else 1)
