# 專案協作規則

- 提供給專案負責人的程式設計、除錯、部署、維護說明一律使用繁體中文；即使提問使用其他語言也一樣。
- App 的使用者介面、調查員提示、Viewer 畫面與西班牙文使用手冊仍保持西班牙文，面向巴拉圭使用者。
- 修改前先讀取既有程式。不要捏造部署網址、測試紀錄、候選人資料或官方投票所。
- 候選人維持目錄順序；只呈現樣本計數與比例，不宣告勝選，不估計選舉勝率。
- 正式部署必須關閉示範角色切換。權限由伺服器驗證，不能只靠前端隱藏按鈕。
- Secret key、service_role、密碼、調查員帳密 CSV、投票回答、GPS 與資料庫備份不得提交到 repository。
- 不停用 RLS、不使用 force push、不覆蓋未讀取的既有程式。測試資料與正式資料分開。
- 執行 node --test tests/*.cjs 與 JavaScript 語法檢查；清楚區分單元測試、介面測試與雲端／實機驗收。

## Supabase 與 App 操作責任（2026-09-27 確認）

- 只有指定 Super Admin（jaimehuang168@gmail.com）操作 Supabase Dashboard、SQL、資料庫升級、Edge Functions、Secrets、備份還原及帳務。
- 公司 Admin、Coordinador、Encuestador 與 Viewer 都只使用 Web App；不要要求公司技術管理員進入 Supabase，也不要交付伺服器金鑰、資料庫密碼或管理 token。
- 013 模組由 Super Admin 安裝一次；三項公司準備確認仍由公司 Admin 在 App 自行保存與確認，不要要求 Super Admin 代填或二次核准。
- 備份還原的技術執行由 Super Admin 負責；公司只記錄無憑證的參考編號。
- App Super Admin 不是自動取得 Supabase 平台權限；平台成員須獨立管理。未查核成員清單時，不能宣稱只有擁有者可進入平台的設定已驗證。
