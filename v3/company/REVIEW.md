# V3.1 公司自助管理反向審查

- Super Admin 使用私有資料表和登入使用者 UUID，不以瀏覽器輸入的信箱或顯示名稱決定。
- 一般 admin 不得建立 admin、管理其他 admin 或 protected owner；舊 Edge／V2 帳號入口也受限制。
- 012 採增量、原子安裝；精確驗證既有 jaimehuang168@gmail.com 為已確認、啟用的 admin，不建立 Auth、不修改密碼、不開收。
- 保留 009 的安全對外代號 wrapper；不得重新打開舊真名快照發布。
- 公司與姓名修改有欄位白名單、版本衝突、同請求重試及稽核。
- 完整瀏覽器測試發現 HTML form 的 name=id 欄位遮蔽 form.id 屬性。已在真正 Chromium DOM 重現；共用 submit 改用 getAttribute('id')，重新驗證姓名修改與問卷回條，不以降低斷言通過。
- 前端發布不等於正式庫已安裝012或使用者已獲正式Super Admin權限。
- 本次不建立付費資源、不在正式庫插入試票、不假填實體手機或最終驗收。
