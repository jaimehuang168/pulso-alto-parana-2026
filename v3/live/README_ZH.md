# Pulso 即時統計展示

調查進行中即可查看，不以投票結束或建立固定截點為前提。`live-demo/` 是編譯時隔離的合成資料示範；`live/` 讀取正式 Supabase 的唯讀 RPC，不能以網址參數切換成假管理者。

## 操作

`4 ciudades`：桌面四格同屏；點城市名稱：單城市放大。`Rotación` 每15秒切城市；`Actualizar` 手動讀取；自動讀取在上一請求完成後5秒執行，另有管理者非敏感 revision 通知刷新。`Pausar` 只暫停螢幕，不停止訪員收件。PNG/CSV 為當下快照，不會自行變動。

管理者可用 `Admin · nombres reales` 對帳；`Privada · códigos` 為私有代號預覽。`Viewer · canal autorizado` 必須有指定城市授權、外部結果開關、已確認代號、有效發布政策與獨立的連續更新授權。代號化不等於可以提前公開發布。外部授權過期或中斷確認時顯示會清除；既有下載無法遠端收回。

## 安裝範圍

先完成 V3 增量安裝，不重跑 V2 初始化。備份並核對目前schema後，依序安裝 `supabase/migrations/009_v3_reports.sql`、`010_v3_live_board.sql`。009 是先前代號報表的資料庫依賴，不包含先前未部署的報表介面；會撤回舊版真名 Viewer 快照。010 不新增問卷、不改候選人、不開放收件或外部發布。

正式網址的 SDK／公開連線設定沿用 `../v3/vendor/supabase.js` 和 `../v3/config.js`。不得填入Secret key。後端尚未安裝時，畫面顯示待升級，不會暗中套用示範數字。

代號由既有已核准流程經 `v3_report_alias_save` 保存；首次未確認時，代號画面顯示待設定，不回退到姓名。連續 Viewer 權限由 admin 經 `v3_live_authorize` 明確核准；一份已發布的固定報告不會自動開通連續觀看。尚未提供的現場發布核定與手機實測不可當成已完成。

## 測試與界線

純函式檢查、實際SQL/PGlite合成身分收件與瀏覽器演練是不同層次。GitHub工作流程應保留各自證據；不可將測試環境結果稱為正式Supabase或iPhone已驗收。程式不得向正式庫輸入測試票。每城市各自計算分母；未收件的離線待傳尚未納入中央統計。

本地建置：`npm --prefix v3 ci` 後執行 `node v3/live/build.mjs`。產物為 `web/live/`、`web/live-demo/` 與 `web/Pulso_LIVE_DEMO_ES.html`；套件使用既有鎖定依賴。
