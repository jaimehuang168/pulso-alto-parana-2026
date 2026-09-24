# Pulso V3 · 現場動態調查

Spanish-first field operations, built as an additive upgrade beside Pulso V2. See `docs/DEPLOY_ZH.md` for the controlled migration and `docs/ARCHITECTURE_ZH.md` for the review boundaries.

## 功能

受限現場主管、動態人員、單次加入碼／QR、必要簡訓與核准、任務派任與本人確認、分點開收、加密待傳、回條對帳、交班與本人復原、逐版本彙總、人工結果快照、完整快照匯出、R3 Excel／CSV建檔、紙本補錄及私有附件。

V2與V3採不同本機儲存名稱。原帳號與舊資料不删除。安裝V3不會自動切換operation_mode，也不會自動開放正式收件。

## Build

```
cd v3
npm ci
node scripts/fetch-vendor.mjs
npm run check
npm test
npm run build
npm run build -- --demo
```

正式設定：`SUPABASE_URL`及`SUPABASE_PUBLISHABLE_KEY`，只放公開連線參數。伺服器Secret只放Supabase EdgeSecrets。輸出dist與preview分開；preview使用瀏覽器內合成SQL資料，不提供真實Auth帳號服務，也不連正式資料庫。

## QA

```
node tests/database.mjs
node tests/enrollment.mjs
python tests/browser.py
```

原生整合另依GitHub V3工作流程使用暫時Supabase CLI堆疊；參見測試矩陣。`evidence/`放實測結果，沒有結果的測試不得當成已通過。正式部署、實體手機與備份放行仍需真實證據。

## 使用者文件

`web/manual-es.html` 可在App的Guía頁開啟；`web/templates/Pulso_R3_Cliente.xlsx`給客戶填寫（不包含密碼）。
