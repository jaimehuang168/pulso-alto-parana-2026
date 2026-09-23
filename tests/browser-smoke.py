"""DOM smoke tests of the standalone practice build, using Chromium.
This managed runner blocks navigation and IndexedDB origins, so set_content()
uses the app's explicit volatile practice fallback. Does NOT prove offline
persistence, real GPS permission, server RLS, WebSocket sync or 60-phone load.
Run with: python tests/browser-smoke.py /path/to/practice.html
"""
import sys,json
from pathlib import Path
from playwright.sync_api import sync_playwright
source=Path(sys.argv[1]);out=Path(__file__).parent/'artifacts';out.mkdir(exist_ok=True)
results=[]
def check(name,condition):
 if not condition:
  print(page.evaluate("[...document.querySelectorAll('body *')].filter(e=>e.getBoundingClientRect().right>innerWidth+1&&getComputedStyle(e).display!='none').map(e=>[e.tagName,e.className,e.getBoundingClientRect().width,e.innerText?.slice(0,60)]).slice(0,30)"))
  page.screenshot(path=str(out/'failure.png'),full_page=True)
  raise AssertionError(name)
 results.append({'test':name,'passed':True});print('PASS',name)
with sync_playwright() as pw:
 browser=pw.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox'])
 page=browser.new_page(viewport={'width':1440,'height':1050});errors=[]
 page.set_default_timeout(5000)
 page.on('pageerror',lambda e:errors.append(str(e)))
 page.on('dialog',lambda d:d.accept('capture_error') if d.type=='prompt' else d.accept())
 page.set_content(source.read_text(),wait_until='load');page.wait_for_timeout(500)
 check('four independent city cards',page.locator('[data-test=district-card]').count()==4)
 check('all twelve candidate names',page.locator('.candidate-name').count()==12)
 check('start at zero, no fabricated support',page.locator('[data-test=total-contacts]').inner_text()=='0')
 check('desktop layout fits',page.evaluate('document.documentElement.scrollWidth <= innerWidth'))
 page.screenshot(path=str(out/'desktop-dashboard.png'),full_page=True)
 def role(role='admin',city='cde',slot='1'):
  page.locator('[data-action=demo-profile]').click();page.locator('#demo-profile-form select[name=role]').select_option(role)
  page.locator('#demo-profile-form select[name=city]').select_option(city);page.locator('#demo-profile-form select[name=slot]').select_option(slot)
  page.locator('#demo-profile-form [type=submit]').click();page.wait_for_timeout(200)
 def nav(screen):
  prefix='.mobilebottom' if page.viewport_size['width']<=760 else '.sidebar'
  page.locator(f'{prefix} [data-screen={screen}]').click();page.wait_for_timeout(150)
 role('interviewer','minga');page.set_viewport_size({'width':390,'height':844});page.wait_for_timeout(100)
 check('mobile capture has four Minga candidates only',page.locator('.choices .choice').count()==4 and 'César Paredes' in page.locator('.choices').inner_text() and 'Rigo Chamorro' not in page.locator('.choices').inner_text())
 check('24px mobile candidate labels',page.locator('.choices .choice strong').first.evaluate('(e)=>parseFloat(getComputedStyle(e).fontSize)')>=24)
 check('large touch targets',page.locator('.choices .choice').first.bounding_box()['height']>=90)
 check('mobile viewport fits at 390px',page.evaluate('document.documentElement.scrollWidth <= innerWidth'))
 page.screenshot(path=str(out/'mobile-capture.png'),full_page=True)
 page.locator('#save-response').click();page.wait_for_timeout(100)
 check('empty response not registered',page.locator('#my-count').inner_text()=='0' and page.locator('#my-pending').inner_text()=='0')
 page.locator('.choices .choice').first.click();page.locator('#save-response').click();page.wait_for_timeout(100)
 check('no-voted confirmation blocks capture',page.locator('#my-count').inner_text()=='0')
 page.locator('[data-action=simulate-offline]').click();page.locator('input[name=voted]').check();page.locator('input[name=consent]').check()
 page.locator('.choices .choice').first.click();page.locator('#save-response').click();page.wait_for_timeout(200)
 check('offline practice event pending, not counted',page.locator('#my-pending').inner_text()=='1' and page.locator('#my-count').inner_text()=='0')
 page.locator('[data-action=simulate-offline]').click();page.wait_for_timeout(300)
 check('restored practice link flushes pending once',page.locator('#my-pending').inner_text()=='0' and page.locator('#my-count').inner_text()=='1')
 page.locator('input[name=voted]').check();page.locator('[data-action=choice][data-outcome=refused]').click()
 check('refusal disables consent and cannot select candidate simultaneously',page.locator('input[name=consent]').is_disabled() and page.locator('.choices [aria-pressed=true]').count()==0)
 page.locator('#save-response').click();page.wait_for_timeout(200)
 check('refusal saved separately as contact',page.locator('#my-count').inner_text()=='2')
 page.evaluate("Object.defineProperty(navigator,'geolocation',{configurable:true,value:{getCurrentPosition:(ok,err)=>ok({coords:{latitude:-25.5,longitude:-54.6,accuracy:12},timestamp:Date.now()})}})")
 page.locator('[data-action=get-gps]').click();page.wait_for_timeout(150)
 check('one-shot simulated GPS shows accuracy', '12' in page.locator('#geo-status').inner_text())
 page.locator('input[name=voted]').check();page.locator('input[name=consent]').check();page.locator('.choices .choice').nth(1).click();page.locator('#save-response').click();page.wait_for_timeout(200)
 nav('records')
 check('journal contains three practice records',page.locator('.journal tbody tr').count()==3)
 text=page.locator('#content').inner_text()
 check('journal includes time and GPS fields','12' in text and '-25.5' in text and 'Inicio:' in text)
 check('interviewer navigation excludes team/settings/results',page.locator('.mobilebottom [data-screen=settings]').count()==0 and page.locator('.mobilebottom [data-screen=dashboard]').count()==0)
 page.screenshot(path=str(out/'mobile-journal.png'),full_page=True)
 role('admin');check('central count includes three contacts',page.locator('[data-test=total-contacts]').inner_text()=='3')
 page.locator('#city-filter').select_option('minga');page.wait_for_timeout(150);page.locator('#station-filter').select_option('minga-p1');page.wait_for_timeout(150)
 check('station drilldown filters to one city',page.locator('[data-test=district-card]').count()==1)
 nav('team');check('station drilldown shows five assigned operators',page.locator('.teamcard').count()==5)
 page.screenshot(path=str(out/'mobile-team.png'),full_page=True)
 nav('records');page.locator('[data-action=void-record]').first.click();page.wait_for_timeout(200)
 nav('dashboard');check('voided contact removed from sample total',page.locator('[data-test=total-contacts]').inner_text()=='2')
 nav('settings');page.locator('[data-action=viewer-toggle]').click();page.wait_for_timeout(200)
 role('viewer');check('viewer remains locked before administrator enables', 'Acceso a resultados pendiente' in page.locator('#content').inner_text())
 check('viewer cannot see journal/team or create button',page.locator('.mobilebottom [data-screen=records]').count()==0 and page.locator('[data-action=provision]').count()==0)
 role('admin');nav('settings');page.locator('[data-action=viewer-toggle]').click();page.wait_for_timeout(150)
 role('viewer');check('authorized practice viewer sees only aggregates',page.locator('[data-test=district-card]').count()==4 and page.locator('[data-action=export-summary]').count()==0)
 page.set_viewport_size({'width':320,'height':740});check('320px dashboard does not overflow',page.evaluate('document.documentElement.scrollWidth <= innerWidth'))
 role('interviewer','franco');check('four Presidente Franco candidates',page.locator('.choices .choice').count()==4 and 'Roya Torres' in page.locator('.choices').inner_text())
 check('320px capture does not overflow',page.evaluate('document.documentElement.scrollWidth <= innerWidth'))
 role('admin');nav('settings');page.set_viewport_size({'width':390,'height':844});
 check('mobile administration fits',page.evaluate('document.documentElement.scrollWidth <= innerWidth'))
 check('candidate and polling-location editors present',page.locator('[data-candidate-row]').count()==2 and page.locator('[data-station-row]').count()==3)
 page.locator('[data-action=reset-demo]').click();page.wait_for_timeout(200)
 check('reset returns to zero without preload',page.locator('[data-test=total-contacts]').inner_text()=='0')
 check('no uncaught JavaScript errors',not errors)
 (out/'browser-results.json').write_text(json.dumps({'passed':len(results),'tests':results,'limitations':'DOM practice mode only. No real IndexedDB persistence/cloud/GPS/network/60-device tests.'},indent=2))
 browser.close()
