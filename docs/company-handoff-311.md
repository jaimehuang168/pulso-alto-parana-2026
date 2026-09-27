# Pulso 3.1.1 · 公司自行完成啟用確認

使用者指定：V2 待傳、備份／還原參考、公司驗收三項由公司 Admin 自己設定，不再要求 Super Admin 代填或核准。

## 操作
公司 Admin：Empresa e inicio → Confirmaciones a cargo de la empresa → Guardar avance de la empresa。允許留白與保存未完成草稿。全部真實確認完成並保存後，再使用 Confirmar como empresa y activar V3。Super Admin 只查看進度與管理帳號，不會再顯示三項輸入或舊啟用彈窗。

## 安裝
由公司技術管理員在現有已安裝004–012的Supabase專案，執行完整 supabase/V3_1_1_COMPANY_HANDOFF.sql。App的Admin權限不等同Supabase SQL權限。網站發布不會自動執行此SQL。不要重裝舊模組，不需要新專案或付費服務。

## 邊界
草稿不等於核准。未完成不會自動通過。公司啟用仍檢查舊資料、狀態、帳號對應、版本與已保存證據；不開收、不改日期、不公開結果。原Super Admin帳號保護不變。操作記錄公司的實際登入身分與時間，不冒用擁有者。

## 自動驗收
runtime d548f089951b8b926262b5b77670082cb5942dd5；run36335951091嚴格總判定成功。新SQL20、原生Auth/Edge/HTTP9+5、Chromium/WebKit操作20、既有公司及問卷模擬22。根目錄127、V3純函式68、舊SQL等回歸亦通過。測試使用隔離本機資料庫，不是正式試票，不代表實體手機驗收或真實公司已簽認。

## Actualización en español
Las tres confirmaciones pertenecen al Admin de empresa. Se guardan borradores, sin activar. El Super Admin mantiene la gestión de cuentas, pero no rellena ni aprueba estas declaraciones. La empresa confirma el avance guardado; la activación no abre puntos ni encuestas, ni autoriza difusión. El módulo 013 debe instalarse una sola vez en el proyecto existente por un responsable técnico autorizado.
