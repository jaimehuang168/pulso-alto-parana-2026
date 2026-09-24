# Pulso V3 部署、切換與復原

此目錄是 V3 候選版本，不能把「前端能開啟」當成正式放行。既有 V2 網站、帳號、問卷、稽核及 IndexedDB 不會被本分支的測試清空。

## 環境邊界

|位置|用途|正式資料|
|---|---|---|
|`v3/preview`|瀏覽器內 PGlite SQL 模擬、明確 DEMO 候選人|沒有；刷新會重新建立模擬伺服器|
|GitHub CI 本機 Supabase|原生 Auth、PostgREST、Edge、Storage、Realtime 與負載測試|只有合成資料，工作結束銷毀|
|`v3/dist`|正式模式靜態檔，需要專用 Supabase 公開設定|不預載任何回答|
|既有正式 Supabase|須由已授權的專案擁有者安裝、驗收、切換|保留，不從 CI 自動清空／重建|

## 1. 先盤點，不要重跑 V2 安裝

在正式專案 SQL Editor 執行 `supabase/V3_PREFLIGHT_EXISTING.sql`。必須確認 V2 必要表及 v2 收件函式存在、目前尚未開始選舉。若舊庫已有問卷或任何手機有 V2 待傳，停止切換，先作逐筆映射／保存方案；本版不會猜測舊資料應歸哪個任務。

下載並驗證資料庫備份，將附件物件另外保存；把復原演練證據、負責人及時間放進核准紀錄。僅填寫一個備份名稱不等於真的做過還原。

## 2. 安裝 V3 增量資料結構

對既有、已完整安裝 V2 的專案，只執行 `supabase/V3_UPGRADE_EXISTING.sql`，不要執行 `00_INSTALL_NEW_PROJECT.sql`。本檔會在一個交易內新增 004–008 的結構、RPC 與 Storage 政策；未知或已有 V3 結構時停止，不刪表。安裝成功仍維持 operation_mode=v2、V3 phase=setup，不開放調查。

使用標準 Supabase CLI migration 管理的新 staging 專案，則依 001–008 順序執行 migrations；不要同時再執行整合 SQL。生產環境由 SQL Editor 安裝的歷史 migration 尚未納入 CLI 時，不可直接 `db push` 讓 001 再跑一次。

## 3. 部署帳號函式

Supabase Edge Functions 新增或更新 `field-enrollment`，內容是 `supabase/functions/field-enrollment/index.ts`。只對這個函式設 `verify_jwt=false`：公開入口只有受限的單次領用；所有管理操作仍呼叫 Auth getUser，再由資料庫檢查有效工作階段、帳號與範圍。

在該專案的 Edge Functions Secrets 設：

```
PULSO_V3_ORIGINS=https://jaimehuang168.github.io
PULSO_SUPABASE_SECRET_KEY=<同一專案的伺服器 Secret key>
```

Origins 不加 `/v3/` 路徑或結尾斜線。秘密金鑰不寫入 config.js、GitHub variables、SQL、Excel、日誌或聊天。V2 的 `provision-team` 更新版另加 V3 模式拒絕檢查；切換時也會撤銷它對舊 App 表的服務角色存取，避免原部署繼續建 V2 帳號。

已登入 Supabase CLI 的維護者可在 repo 根目錄執行：

```
npx supabase@2.117.0 functions deploy field-enrollment --project-ref <專案參考ID> --use-api
```

這個指令只部署函式，不安裝 SQL、不建立秘密金鑰、不開放調查。

## 4. 建置前端

需 Node.js 22。進入 `v3`，執行 `npm ci`（已有 lockfile 時）或固定版本 `npm install`。`node scripts/fetch-vendor.mjs` 會下載固定 SDK 並核對 SHA-256。設定 SUPABASE_URL、SUPABASE_PUBLISHABLE_KEY，然後 `npm run build`。

Public key 是 sb_publishable 或 legacy anon JWT，絕不能填 sb_secret / service_role。輸出 `v3/dist` 可部署到独立 HTTPS 網站或同網域 `/v3/` 子目錄。正式包不含模擬帳號開關與 PGlite 資料庫。`npm run build -- --demo` 是另一份含明顯模擬標示的展示站，不應代替正式 App。

V3 使用新的 IndexedDB 名稱與獨立 Auth storage key，不改寫 V2 待傳。切換後關閉舊 V2 分頁，不要求使用者清除瀏覽器資料。

## 5. 安装後端到端驗收

以真實管理者登入，測試一位主管、一位臨時訪員及 Viewer。驗證單次加入碼、不同手機重複兌換、訓練、核准、派任、版本確認、首次開點、逐筆收件、精確 UUID 重送、改派、離線補傳、停用與資料讀取範圍。先使用獨立 staging 真實問卷，不要改正式選舉日期來製造假票。

Android Chrome 與 iPhone Safari／加入主畫面都需測試實機的鍵盤遮擋、重啟、儲存壓力、定位拒絕、斷線與重新登入。Playwright WebKit 不是實體 iPhone 驗收。

## 6. 受控切換（不是立即開放收件）

V3 Configuración → Comprobar migración 顯示 preflight。確認無舊待傳、備份／還原證據、實機／範圍驗收完成後，才填入切換核准參考。`v3_activate` 會關閉舊 App RPC 的讀寫與舊表讀取，保留所有資料；既有模式轉為 V3，但 phase 仍為 setup。新增V2帳號／停用狀態在擴充後產生差異時會擋下，需先核對，不靜默同步。

最後核對日期、範圍、問卷來源與保留政策。進入作業日期後啟動全域作業，再按點開放，不要求四市或 60 人到齊。Viewer 另行核准與發布城市靜態快照，不隨收件自動開放。

## 7. 事故與復原

有 V3 資料後不直接退回 V2 再收件。發生重要問題：全域暫停 → 保存本機待傳與伺服器回條 → 確認最後成功UUID → 提供相容版／前向修正 → 對帳。禁止以舊備份覆蓋後來已收件的資料。

丟失手机／疑似冒用：撤銷任務裝置、停用帳號；斷線裝置不能立即收到停用通知，但重新送件仍受後端驗證。舊已結束任務在新登入工作階段恢復，只允許同一人的「補傳復原」，原始內容不改動，一律入待審，不自動計入統計。

加密本機密語無法由管理者重設解密。忘記密語時保留檔案，不刪除、不把不同人的帳密輪流試進去。已有伺服器回條資料不受本機密語遺失影響。

## 放行缺一不可

原生後端正向與負向測試、實體手機、正式環境已安裝狀態、備份還原、核定的候選人／調查點與方法、主管授權、服務方案容量、法規與發布政策。填寫核准欄位不能替代這些證據。
