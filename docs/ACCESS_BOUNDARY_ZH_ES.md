# 權限與操作分工 / Separación de accesos

確認日期 / Fecha: 2026-09-27

## 繁體中文

**Supabase 僅由指定 Super Admin（jaimehuang168@gmail.com）操作；其他所有人都只使用 Web App。**

| 工作 | 負責人與位置 |
|---|---|
| SQL、安裝 012／013、資料庫維護、Edge Functions、Secrets、備份還原、帳務 | 僅 Super Admin 在 Supabase 操作 |
| 建立及管理公司 Admin | Super Admin 在 Web App 操作 |
| 公司資料、候選人、地點、訪員、一般帳號、任務及報告 | 公司 Admin 在 Web App 權限內操作 |
| V2 待傳、備份還原紀錄參考、公司驗收三項確認 | 公司 Admin 在 Empresa e inicio 自行保存與確認 |
| 主管、訪員、Viewer 的各自工作 | 僅在 Web App 的授權範圍內操作 |

013 的一次性安裝由 Super Admin 執行，不交給公司技術管理員。不重裝 004–012，不要求任何一般使用者複製 SQL、填專案連線或取得伺服器憑證。

備份／還原的技術工作由 Super Admin 執行，公司僅在 App 登錄實際紀錄的參考編號，不需登入 Supabase。這不改變由公司自己確認三項準備的安排：Super Admin 不代填、不作第二次核准。公司按 App 啟用後由伺服器執行受限流程，並不取得 Dashboard 管理權。

App 角色與 Supabase 組織／專案成員是兩套權限。不要將公司人員邀請為 Supabase 團隊成員，不分享 Secret key、service_role、資料庫密碼或管理 token。App 使用公開金鑰搭配個人登入及伺服器權限是正常架構，並非向人員開放後台。

本次只更正操作分工與文件；未查核或變更 Supabase 的實際團隊成員，未執行正式 SQL、備份、啟用或收件，未建立付費資源。若過去曾授予他人平台權限，須由擁有者在 Supabase 成員設定另行核對；不能以修改 App 角色代替撤銷平台成員資格。

## Español

**Solo el Super Admin designado (jaimehuang168@gmail.com) administra Supabase. Todas las demás personas operan exclusivamente en la Web App.**

El Super Admin realiza SQL, instalaciones 012/013, mantenimiento, despliegue de Edge Functions, gestión de secretos, respaldos/restauraciones y facturación. En la Web App administra las cuentas de otros Admin.

El Admin de empresa gestiona datos, usuarios de menor privilegio, tareas e informes dentro de la App. En Empresa e inicio guarda y confirma las colas V2, la referencia del respaldo/restauración y la aceptación empresarial. Puede guardar avances; no recibe acceso a Supabase ni necesita una segunda aprobación del Super Admin.

La instalación única de 013 corresponde al Super Admin, no a un técnico de la empresa. El respaldo y la restauración los ejecuta el Super Admin; la empresa registra una referencia sin credenciales. No se inventan confirmaciones ni se comparten secretos.

Los roles de la App no conceden membresía en la organización/proyecto de Supabase. No invite a los usuarios operativos al equipo de Supabase ni comparta claves secretas, service_role, contraseñas de base o tokens de gestión. La clave pública con autenticación y permisos de servidor no equivale a acceso al Dashboard.

Esta corrección documental no verifica ni modifica miembros reales, no ejecuta migraciones ni activa encuestas y no crea recursos de pago. Los accesos al Dashboard concedidos anteriormente deben revisarse por separado por el propietario.

## Referencias oficiales

- https://supabase.com/docs/guides/platform/access-control
- https://supabase.com/docs/guides/getting-started/api-keys
