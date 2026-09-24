# 測試與驗收矩陣

|領域|程式測試|外部驗收|
|---|---|---|
|輸入、角色畫面、CSV與回條|core.test.mjs|客戶實際操作理解度|
|城市／調查點／任務權限、版本與資料不變|database.mjs（PGlite）|正式Schema安裝與角色配置|
|一次性開通、限速、saga重試|enrollment.mjs + native.mjs|正式API key與Auth額度|
|原生Auth/Edge/PostgREST/Storage/Realtime|native.mjs（本機Supabase CLI）|正式後端一次受控正向／負向操作|
|UI及加密IndexedDB|browser.py（Chromium/WebKit）|Android與iPhone實機、實際鍵盤、主畫面模式|
|60／120人、集中3000筆补传、UUID併发|load-native.mjs|正式方案、行動網路、尖峰熱點|
|實際備份還原|CI restore script|正式備份與Storage物件保存、復原責任人|
|資料建檔、角色完整流程|原生浏览器+資料庫测试|客戶資料、來源与調查授權|

所有測試資料須標示synthetic；Native測試拒絕非localhostURL；機密只存在/tmp不作artifact。原生Auth伺服器錯誤、timeout、無法安裝引擎都算失敗，不視為skip成功。

关键禁止上线項：跨區讀寫、角色升級、邀請碼串號、原問卷改歸屬、未確認數據靜默刪除、UUID重複計入、直接匯入覆蓋历史、舊App繞過切換後授權、無備份與實機驗收。
