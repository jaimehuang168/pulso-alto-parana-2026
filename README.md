# Pulso · Alto Paraná 2026

四城市出口民調 Web App。App 與操作手冊採西班牙文；程式設計、部署與維護說明採繁體中文。

## 從這裡接續，不要重新建立 repository

這個 repository 已存在。首次匯入改用**上傳一個完整 ZIP，由 GitHub Actions 驗證並展開原始碼**；不必逐檔上傳，也不必先安裝 Git。

1. 使用專案負責人收到的 `Pulso_v2_Deploy_ZH_ES.zip`，不要改名、不要重新壓縮。
2. 在本 repository 首頁選 **Add file → Upload files**，上傳該 ZIP，提交到 `main`。
3. 到 **Actions → Import Pulso package** 確認成功。SHA-256 不符、缺檔或既有程式不同時，會停止而不覆蓋。
4. 匯入成功後，**Deploy Pulso frontend** 會檢查程式。沒有連線設定時只做檢查、跳過發布，不產生可用網站。
5. 安裝專用 Supabase 後，設定 `SUPABASE_URL` 與 `SUPABASE_PUBLISHABLE_KEY`，並在 **Settings → Pages → Source** 選 **GitHub Actions**，再執行 **Deploy Pulso frontend → Run workflow**。

完整步驟見 [`docs/CONTINUE_DEPLOY_ZH.html`](docs/CONTINUE_DEPLOY_ZH.html)；該文件隨完整 ZIP 匯入。原先手冊中的「建立新的 repository」步驟不再適用於這個既有 repository。

## 狀態要分開判讀

- **原始碼匯入成功**：GitHub 已收到 App 與文件，不等於網站上線。
- **程式檢查通過、deploy 跳過**：仍缺公開連線設定或前置步驟。
- **GitHub Pages 部署成功**：前端已發布；仍不代表資料庫、角色權限與 60 人同步已驗收。
- 正式收件前仍須安裝 Supabase SQL、建立第一位管理者、部署 `provision-team`、填入真實投票所、建立及分配 60 個帳號，完成手機與負載測試。

## 可選的終端機接續方式

原始碼匯入後，在完整專案資料夾使用 Node.js 與已登入的 GitHub CLI：

```powershell
node scripts/continue-deploy-zh.mjs --check
node scripts/continue-deploy-zh.mjs --publish
```

`--check` 不更動設定。`--publish` 要求本機確認，只設定公開連線參數、Pages 與建置流程，不自動建立或替換資料庫；不要求 Secret key。

## 安全與資料範圍

不收集選民姓名、證件、電話或照片。位置為指定投票所與選填的調查員手機定位。權限分為 Administrador、Encuestador、Viewer；Viewer 預設關閉。

統計為非加權樣本計數與比例，不是官方開票結果；不預測或宣告勝選。候選人與 Lista 由專案負責人提供，正式收件前仍須核實；練習投票所不代表官方名單。

不得把 Secret key、service_role、密碼、調查員帳密 CSV、回答明細、GPS 或資料庫備份提交到公開 repository。提供給專案負責人的說明語言規則見 [`AGENTS.md`](AGENTS.md)。
