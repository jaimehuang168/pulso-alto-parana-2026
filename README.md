# Pulso · Alto Paraná 2026

四城市出口民調 Web App。App 與使用者操作手冊採西班牙文；提供給專案負責人的程式設計、部署及維護說明採繁體中文。

## 部署狀態

此 repository 已建立，正在匯入經檢查的 Pulso v2 原始碼。**程式碼提交不等於網站已上線，也不等於 Supabase 已完成安裝或通過實機驗收。**

正式系統需要 GitHub Pages 前端，以及同一個專用 Supabase 專案的 Authentication、PostgreSQL 權限規則與 `provision-team` Edge Function。未完成設定前不得收集正式問卷。

## 重要限制

- 不收集選民姓名、證件、電話或照片。位置是指定投票所與選填的調查員手機定位。
- 角色分為 Administrador、Encuestador、Viewer；Viewer 預設關閉。
- 僅呈現非加權樣本統計，不是官方開票結果，不預測或宣告勝選。
- 候選人與 Lista 由專案負責人提供，須於正式收件前核實；練習投票所不代表官方名單。
- 不得將密碼、Secret key、service_role、調查紀錄、GPS 或帳號 CSV 提交到這個公開 repository。

## 下一個檢查點

待原始碼匯入完成後，依繁體中文部署接續指南設定 GitHub Pages 與兩個公開連線參數。不要再次建立同名 repository，也不要刪除既有專案來排除設定錯誤。
