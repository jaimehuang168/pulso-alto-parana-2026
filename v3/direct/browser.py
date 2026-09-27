"""Run the existing native browser workflow with additional direct-use assertions."""
from pathlib import Path
R=Path(__file__).resolve().parents[2]
p=R/'v3/tests/company-native-browser.py';s=p.read_text()
needle="def idle(page):"
extra="""def direct_checks(page,engine):
 page.locator('[data-company-readiness]').wait_for(timeout=20000)
 page.get_by_text('Acceso directo V3.1',exact=True).wait_for(timeout=20000)
 check(engine+' authenticated page shows direct V3.1 use',True)
 check(engine+' no activation or mandatory readiness form',page.locator('[data-action=activate],[data-action=company-activate],#company-readiness-form').count()==0)
"""
assert needle in s;s=s.replace(needle,extra+needle,1)
a="nav(page,'company');page.locator('#company-form [name=name]')";b="nav(page,'company');direct_checks(page,engine+' owner');page.locator('#company-form [name=name]')"
assert a in s;s=s.replace(a,b,1)
a="nav(page,'company');check(engine+' mobile company";b="nav(page,'company');direct_checks(page,engine+' company');check(engine+' mobile company"
assert a in s;s=s.replace(a,b,1)
s=s.replace('company-native-browser','direct-native-browser')
exec(compile(s,str(p),'exec'),{'__file__':str(p),'__name__':'__main__'})
