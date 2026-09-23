# Pulso v2｜中文部署與操作指南

**適用日期：2026 年 9 月 22 日。選舉設定：2026 年 10 月 4 日、四市市長選舉。**

## 先看目前狀態

新版示範與原始碼已完成，但本次尚未建立 GitHub repository、發佈 GitHub Pages 網站或安裝 Supabase 資料庫。因此目前沒有可提供給 60 支手機共用的正式網址。GitHub 連線已確認帳號，但本次工具只提供讀取操作。以下腳本讓你在自己的 Windows 電腦完成授權與發佈；不需要把任何 GitHub token 或後端秘密金鑰傳到聊天中。

介面示範可以立即試用；正式上線還需要後端安裝、投票所資料、正式帳號及驗收。不要用示範檔收集正式調查。

## 1｜立即操作新版示範

開啟另附的 `Pulso_Boca_de_Urna_v2_ES.html`，不需安裝 Python。管理面板從零筆開始，候選人依你提供的名單；所有示範投票所清楚標記 NO OFICIAL，並非官方投票所資料。

右上角 **Cambiar rol** 可在示範中切換 Administrador、Encuestador、Viewer。選 Encuestador 後，選城市與 01–15 號調查員。點 **Abrir perfil** 進入手機問卷。正式版沒有這個角色切換器，必須用個人帳號登入。

調查流程：確認已投票 → 確認匿名自願受訪 → 選候選人或其他答案 → 可選擇取得自己的 GPS → Guardar encuesta。拒訪時不填投票偏好。每筆另外保存完成時間及伺服器收件時間。測試 Simular sin conexión 時，紀錄只在待傳區，恢復連線並收到確認後才納入統計。

某些預覽器、無痕模式或瀏覽器政策禁止本機儲存；示範會清楚顯示「此預覽不會在關閉後保留資料」。這不是正式離線功能。正式版在本機儲存不可用時不允許連接雲端調查。

## 2｜正式版資料與權限

四城市各保留 15 個獨立調查員名額。可設定一市多個投票所，不限制為示範的三個；同一投票所可分配多位調查員。開放正式收件後，候選人、投票所及調查員選區／投票所配置鎖定，避免把前後不同口徑混在一起。人員顯示姓名、帳號停用及 Viewer 開關仍可管理。

| 角色 | 可操作內容 | 不提供的內容 |
|---|---|---|
| Administrador | 四市彙總、投票所、逐員數量、逐筆紀錄、調查員 GPS、帳號與匯出 | 無法把前端介面當作官方開票系統 |
| Encuestador | 指派投票所、自己的問卷、待傳與自己的紀錄 | 其他人的逐筆紀錄、全區結果及管理頁 |
| Viewer | 管理者允許的城市／投票所彙總 | 登錄、修改、帳號、人員 GPS、逐筆問卷及匯出 |

Viewer 預設關閉。管理者可啟用，但這不是符合選舉發布法規的自動保證。

位置分為投票所地址／授權調查點，以及選填的調查員手機 GPS。每次定位須按鈕觸發及取得瀏覽器同意；沒有持續背景追蹤。位置過舊會標記為失效，不冒充最新定位。沒有 GPS 時仍保存指定投票所。手機時間與 GPS 可受裝置設定影響，不是獨立的到場證明。

## 3｜建立專用 Supabase 專案

在你自己管理的 Supabase 帳號建立一個**全新、專用**的 project。不要把安裝 SQL 貼到其他業務的既有資料庫。服務方案、備份、保存期間及費用需由帳號管理者確認；本次沒有建立付費資源。

到 SQL Editor 執行 `supabase/00_INSTALL_NEW_PROJECT.sql`。這個檔案已依序包含 001 及 002，不要再重複執行兩份 migration。它建立資料表、權限、統計函式與 12 位候選人，正式資料保持零筆，狀態為 setup。若執行失敗，保留錯誤訊息供修正，不要先關閉 RLS 或放寬成所有人讀寫。第二階段不接受已存在正式調查或已開放的舊版資料；遷移舊系統必須另作計畫。

若以 migration CLI 管理，改為依序執行 migrations，不要同時用整合 SQL。先完成測試專案，再安裝正式專案。

## 4｜建立第一位管理者

到 Supabase Authentication → Users 建立管理者帳號，使用你自己的可管理電子郵件與獨立強密碼。不要開放公眾自行註冊，也不要設定「註冊即成為 admin」的觸發器。

用文字編輯器打開 `supabase/02_bootstrap_admin.sql`，把 `REPLACE_WITH_COORDINATOR_EMAIL` 換成剛建立帳號的電子郵件，再到 SQL Editor 執行。這一步只授權該帳號為管理者；不在前端寫死密碼。第一位管理者登入時請用該電子郵件，而不是 COORD-01。其他透過 App 建立的 ADMIN-/VIEW-/調查員代碼則可用代碼登入。

## 5｜部署帳號管理函式

此步驟用 Supabase CLI，在專案根目錄執行。請先依官方文件安裝 CLI，建議把使用版本固定；`supabase/config.toml` 已包含本函式設定，勿覆寫成空白。

```powershell
supabase login
supabase link --project-ref 你的PROJECT_REF
supabase functions deploy provision-team --project-ref 你的PROJECT_REF --use-api
```

在 Supabase 的 Edge Function Secrets 設定：

| 名称 | 填寫內容 |
|---|---|
| `APP_ORIGIN` | 網站來源，例如 `https://你的GitHub帳號.github.io`。只填 origin，不加 repository 子路徑 |
| `PULSO_SUPABASE_SECRET_KEY` | 專門給伺服器使用的 Supabase secret key；只能留在 Supabase Secrets |

`SUPABASE_URL` 由執行環境提供。程式也保留 service-role 的相容讀取方式，但新專案建議使用 secret key。不要把 secret key、service_role 或資料庫密碼填入 `web/config.js`、GitHub variables 或聊天。

函式的 `verify_jwt=false` 不是無驗證開放：函式內仍必須使用 Supabase Auth 驗證使用者 token，再查資料庫中的 active administrator。這段檢查不可刪除。必須完成未登入、Viewer、調查員直接呼叫函式都被拒絕的驗收。

官方部署指引：https://supabase.com/docs/guides/functions/deploy

## 6｜從 Windows 發佈 GitHub Pages

需要 Git、GitHub CLI (`gh`) 及 Node.js。由各自官方安裝來源取得，安裝後重新開啟 PowerShell。不需要 Python，也不需要把秘密 token 寫進腳本。

將 ZIP 解壓到一個新資料夾，進入專案根目錄後執行：

```powershell
.\scripts\Deploy-GitHub.ps1
```

腳本會確認 GitHub 登入；必要時開瀏覽器登入。預設準備建立一個**新的公開原始碼** repository：`pulso-alto-parana-2026`。建立前會要求你完整輸入 repository 名稱確認。若同名 repository 已存在，或該資料夾已有 `.git`，腳本會停止而不覆盖。需要別的名稱時：

```powershell
.\scripts\Deploy-GitHub.ps1 -RepoName 'pulso-municipales-2026'
```

腳本只索取兩個**可公開的連線設定**：Supabase project URL，以及以 `sb_publishable_` 開頭的 publishable key。它們會成為 GitHub repository variables。真正授權仍由登入與資料庫規則控制，publishable key 本身不是密碼。

GitHub Actions 會跑計算測試、下載固定版本 SDK、產生公開設定、上傳 `web/` 並部署 GitHub Pages。腳本等 workflow 成功後才顯示 GitHub API 回傳的實際網址。若 Pages 自動啟用失敗，依提示到 Settings → Pages → Source 選 GitHub Actions，再重新執行工作流程。腳本停止時不表示網站已上線。

GitHub Pages 只能提供靜態網頁，不能代替 Supabase 資料库。登入頁是公開網址，但投票回答、GPS、CSV 與帳號密碼不可放進 repository。免費方案與私人 repository 的支援範圍需按 GitHub 帳號方案確認；這份腳本只針對經你確認的新公開原始碼 repository，不會把既有私人專案改成公開。若需私人原始碼，改按 GitHub 官方文件手動配置。

正式發佈 `web/` 不包含示範角色切換器。`_headers` 在 GitHub Pages 不會被執行；如另部署至支援該檔案的主機，才會套用其中的 HTTP headers。不要把它誤當成 Pages 上已存在的保護。

GitHub Pages 官方指引：https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages

## 7｜在 App 配置投票所及人員

管理者登入 → Administración → Candidaturas y locales。逐城市填入實際投票所名稱、代碼、地址、授權調查點，以及選填的投票所經緯度。不能保留範例名稱／空白地址後就開放正式收件。候選人與 Lista 已依提供名單填好，仍需與當次官方登記名單核對。

按 Crear 60 encuestadores 建立帳號，並把一次性帳密 CSV 保存到**repository 以外的私人位置**。每個人只收到自己的帳密，不能把全部名單放在公開群組或 GitHub。新建帳號會輪流分配到各市有效投票所，管理者必須在 Equipo 重新確認及修改每位人員的實際分工。第一次建立時不是已經知道你的人員姓名或排班。

Viewer 與新增管理者在 Crear viewer / administrador 建立；指定 Viewer 看全部四市或單一城市。只有管理者能建立／停用帳號。重設密碼由管理者執行；自行改密碼可由 Guía 進入。

完成採樣規則、工作點及班次，確認正確選舉職位與日期，才勾選已核實目錄。正式系統只允許在設定選舉日期開放，且必須每市有 15 名可用且有配置的調查員。要提前演練，請用**獨立測試專案**把演練日期改成當天，不要在正式庫混入測試資料。

## 8｜正式發出手機連結前的驗收

必須在同一個測試後端用至少兩支真正手機，以及獨立管理者畫面，確認資料同步；再執行 60 帳號的併發／尖峰回補測試。詳細清單在 `docs/ACCEPTANCE.md`。程式碼備齊不代表這些項目已驗收。

特別確認：重複送相同 UUID 不重算；改 UUID 內容被拒；調查員偽造別的投票所被拒；Viewer 直接呼叫寫入 API／逐筆 API 被拒；停用帳號立即失去資料權限；關掉網路、存問卷、關閉重開 App 後待傳仍在；恢復連線後只納入一次；iPhone/Safari 及 Android/Chrome 各自測試定位權限與儲存。

只儲存本機但未取得收件確認的資料，中央無法知道；不能用中央數字推算離線手機目前有多少筆。禁止清除待傳手機的瀏覽器資料、借帳號跨人使用或在收件期間任意更換網址／資料庫。

## 9｜統計解讀與發布

各城市候選人維持目錄順序，沒有勝選標章或預測排名。百分比分母是明確回答某候選人的筆數；空白、廢票、不透露與拒訪另列。這是非加權的樣本比例，不是全體投票結果；問卷回覆率也不是投票率。需要代表性、加權或信賴區間時，必須另行設計並驗證採樣方法。

BACN 公布的選舉法第 306 條限制在規定關閉投票所時間後一小時以前，發布出口民調結果。私人 Viewer、群組、截圖、CSV 不會自動豁免。啟用 Viewer 前應確認當次適用規範、正式關閉時間及實際發布方式；本版不假設固定下午幾點自動解鎖。

法條來源：https://www.bacn.gov.py/leyes-paraguayas/2346/ley-n-834-establece-el-codigo-electoral-paraguayo

日期來源（TSJE）：https://www.tsje.gov.py/noticias/leer/11975-avanza-cronograma-electoral-para-las-elecciones-municipales-2026.html

## 仍須提供或確認的資料

四市真正的投票所清單（名稱、地址、調查點）、60 人姓名／代碼分配與班次、官方候選人核對結果、採樣與拒訪記錄規則、資料保存期限、正式 Supabase 專案及 GitHub 發佈執行權限。本則訊息沒有收到新參考附圖，因此外觀沿用原版並重新放大設計，沒有聲稱已照未提供的圖片重製。
