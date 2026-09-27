from pathlib import Path
R=Path(__file__).resolve().parents[2]
p=R/'docs/build-company-manuals.py';s=p.read_text()
if 'from direct_use_policy' not in s:
 s=s.replace('from owner_only_access import apply_policy, NOTICE_ES, NOTICE_ZH','from owner_only_access import apply_policy\nfrom direct_use_policy import apply_direct_policy, NOTICE_ES, NOTICE_ZH')
 s=s.replace('data=apply_policy(json.loads(source.read_text()))','data=apply_direct_policy(apply_policy(json.loads(source.read_text())))')
 s=s.replace('3.1.1','3.1.2').replace('los módulos 012/013','el modo de acceso directo 014').replace('012／013 模組','014 直接使用模式')
 p.write_text(s)
p=R/'AGENTS.md';s=p.read_text();old='- 013 模組由 Super Admin 安裝一次；三項公司準備確認仍由公司 Admin 在 App 自行保存與確認，不要要求 Super Admin 代填或二次核准。'
new='- 013/014 由 Super Admin 以 V3_1_DIRECT_USE.sql 一次檢查更新。公司與使用者直接登入，不再有 Activate 或三項必填聲明；不虛構已完成驗收，不自動開收或發布。'
s=s.replace(old,new);p.write_text(s)
