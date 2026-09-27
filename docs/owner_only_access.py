"""Documentation policy only. Does not grant cloud or application permissions."""
from copy import deepcopy

NOTICE_ES = ('Acceso a Supabase: exclusivamente el Super Admin designado, '
             'jaimehuang168@gmail.com. Los Admin de empresa, coordinadores, '
             'encuestadores y viewers operan solamente en la Web App. '
             'Crear una cuenta de la App no concede acceso al Dashboard, '
             'SQL Editor, secretos ni facturación. Las tres confirmaciones '
             'siguen a cargo de la empresa dentro de la App.')
NOTICE_ZH = ('Supabase 僅由指定 Super Admin（jaimehuang168@gmail.com）操作；'
             '公司 Admin、主管、訪員及 Viewer 全部只使用 Web App。'
             '建立 App 帳號不授予 Dashboard、SQL Editor、金鑰或帳務權限。'
             '三項確認仍由公司在 App 內自行完成。')

def apply_policy(base):
    """Render the documented owner-only boundary without modifying base records."""
    data = deepcopy(base)
    by_id = {s['id']: s for s in data}
    if len(data) != 26 or sum(len(s['blocks']) for s in data) != 131:
        raise ValueError('Manual structure changed; review policy locations first')
    replacements = {
        ('03', 0): (
            'Esta sección es exclusiva del Super Admin designado, jaimehuang168@gmail.com. Ningún Admin de empresa, coordinador, encuestador o viewer debe entrar en Supabase ni ejecutar SQL. V3_1_COMPANY_UPGRADE.sql exige versiones 4–11 y la cuenta designada confirmada, activa y administrativa; no crea usuarios de Auth ni cambia contraseñas.',
            '本節僅供指定 Super Admin（jaimehuang168@gmail.com）操作。公司 Admin、主管、訪員與 Viewer 不進入 Supabase，也不執行 SQL。V3_1_COMPANY_UPGRADE.sql 要求既有版本 4–11 及已確認、啟用中的指定管理者；不建立 Auth 使用者、不變更密碼。'),
        ('03', 1): (
            'El Super Admin conserva la evidencia de respaldo ya obtenida. Solo él abre SQL Editor → New query en el proyecto correcto y ejecuta el archivo completo que falte. No se crean proyectos para repetir pruebas ya documentadas. Un propietario distinto provoca la reversión de la transacción; no se repite el instalador V2.',
            'Super Admin 保管先前已取得的備份證據，僅由他在正確專案開啟 SQL Editor → New query，執行尚未安裝的完整檔案。不為重複已記錄的測試建立新專案。指定擁有者不符時交易會回復；不重跑 V2 初始化。'),
        ('03', 4): (
            'Vuelva a entrar en /v3/. El propietario debe ver Super Admin · propietario y Empresa e inicio. Si aparece Actualización de empresa pendiente, el Admin de empresa informa al Super Admin sin cambiar claves ni permisos. Solo el Super Admin comprueba el entorno e instala 012 o 013 si falta. Instalar 013 no equivale a confirmar los tres requisitos por la empresa, ni abre encuestas.',
            '重新登入 /v3/ 後，擁有者應看見 Super Admin · propietario 與 Empresa e inicio。公司 Admin 若看到 Actualización de empresa pendiente，只需通知 Super Admin，不更換金鑰或權限。僅 Super Admin 核對環境並安裝缺少的 012 或 013。安裝 013 不代表替公司確認三項準備，也不開放收件。'),
        ('04', 0): (
            'Super Admin · propietario: en esta instalación, jaimehuang168@gmail.com es el único responsable humano autorizado para administrar Supabase, SQL, migraciones, Edge Functions, secretos, respaldos y facturación. Desde la App administra las cuentas de otros Admin. No rellena ni aprueba en nombre de la empresa sus tres declaraciones.',
            'Super Admin · propietario：本套安裝僅授權 jaimehuang168@gmail.com 操作 Supabase、SQL、版本更新、Edge Functions、金鑰、備份與帳務；另可在 App 管理其他 Admin 帳號。他不代填或代核准公司的三項聲明。'),
        ('04', 1): (
            'Administrador de empresa: trabaja exclusivamente en la Web App para configurar empresa, operativo, candidaturas, locales, puntos, personas, tareas, coordinadores y viewers; revisa registros, códigos e informes y completa las confirmaciones de la empresa. No puede crear o administrar otros Admin, alterar al propietario, entrar en Supabase ni recibir credenciales técnicas.',
            '公司 Admin：僅在 Web App 設定公司、作業、候選人、投票所、調查點、人員、任務、主管與 Viewer，處理紀錄、代號、報告及公司確認。不能建立或管理其他 Admin、變更擁有者、進入 Supabase 或取得技術憑證。'),
        ('04', 5): (
            'Super Admin es un rol de la App, no un superusuario PostgreSQL ni una membresía automática de Supabase. El acceso al Dashboard se controla por separado en los miembros de la organización/proyecto; en esta instalación debe reservarse al propietario designado. No se invita a usuarios de la App al equipo Supabase ni se comparten secretos, service_role, contraseñas de base o tokens de gestión. La App puede usar una clave pública con sesión y permisos limitados. Este manual no verifica ni cambia la lista real de miembros.',
            'Super Admin 是 App 角色，不是 PostgreSQL 超級使用者，也不會自動取得 Supabase 成員資格。Dashboard 權限由組織／專案成員另行控制，本套安裝應僅保留指定擁有者。不將 App 使用者邀請為 Supabase 團隊成員，不分享 Secret key、service_role、資料庫密碼或管理 token。App 可使用公開金鑰搭配登入與受限權限；本手冊沒有查核或變更實際成員名單。'),
        ('16', 1): (
            'La empresa define en la App su política de conservación y sus responsables. Si una tarea requiere respaldo, restauración, secretos o mantenimiento de base, la ejecuta solamente el Super Admin. La empresa recibe una referencia o constancia sin credenciales técnicas; guardar el texto no ejecuta ni programa esa tarea.',
            '公司在 App 填寫保存政策與負責人。若工作需要備份、還原、金鑰或資料庫維護，僅由 Super Admin 執行。公司取得不含技術憑證的紀錄編號或證明；儲存文字不會執行或排程該工作。'),
        ('16', 2): (
            'Preflight de migración es una lectura. En Empresa e inicio, el Admin de empresa guarda las tres confirmaciones: colas V2, referencia del respaldo/restauración realizados por el Super Admin y aceptación firmada por la empresa. Puede guardar parcialmente. El Super Admin entrega la referencia técnica sin rellenar la declaración empresarial. Confirmar como empresa y activar V3 se ejecuta desde la App con validación del servidor, cierra V2 y no abre encuestas; no requiere acceso a Supabase ni segunda aprobación del Super Admin.',
            'Preflight de migración 是唯讀檢查。公司 Admin 在 Empresa e inicio 保存三項確認：V2 待傳處理、Super Admin 執行的備份／還原紀錄參考、公司簽認驗收；可以分批儲存。Super Admin 提供技術紀錄，不代填公司聲明。Confirmar como empresa y activar V3 由公司在 App 操作並經伺服器驗證，關閉 V2 但不開收；不需登入 Supabase，也不需 Super Admin 再次核准。')
    }
    for (chapter, index), (es, zh) in replacements.items():
        by_id[chapter]['blocks'][index] = {'es': es, 'zh': zh}
    by_id['03']['title_es'] = 'Instalación y Supabase: solo Super Admin'
    by_id['03']['title_zh'] = '安裝與 Supabase：僅限 Super Admin'
    return data
