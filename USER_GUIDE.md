# 碳粉匣序號簽章工具使用指南

## 執行需求

- 64 位元 Windows 10 1903 以上版本或 Windows 11。
- Windows PowerShell 5.1 與 .NET Framework 由支援的 Windows 版本提供；不需要安裝 Visual Studio、CMake、vcpkg 或 OpenSSL 才能執行已打包的程式。
- 執行帳號需能寫入自己的 `%LOCALAPPDATA%` 資料夾。

## 啟動

從 [GitHub Releases 下載](https://github.com/brianshih04/toner-serial-signature/releases/latest/download/TonerSerialSignature.exe)，再執行 `TonerSerialSignature.exe`。若從原始碼自行打包，執行 `dist\TonerSerialSignature.exe`。第一次啟動會把內含的 C 工具和授權文字解壓到：

```text
%LOCALAPPDATA%\TonerSerialSignature\
```

程式不需要系統管理員權限。若 Windows 顯示未知發行者，表示這個開發版尚未使用組織的程式碼簽章憑證簽署；請依公司軟體核准流程處理。

## 介面操作

### 產生測試金鑰

1. 開啟「產生測試金鑰」頁，設定金鑰 ID（`01` 至 `FF`）。
2. 指定加密私鑰檔案、公鑰資料夾，輸入兩次相同的測試密碼。
3. 按「產生測試金鑰」。公鑰會存為 `key-XX.pem`；既有檔案不會被覆寫。

測試密碼需為 16 至 1024 個不含空白的 ASCII 字元。私鑰檔案仍是敏感資料，請限制存取並使用安全的備份方式。不要把私鑰或密碼放進 GUI 執行檔、碳粉匣或機台韌體。

### 工廠簽發（示範）

1. 選取與金鑰 ID 對應的加密私鑰並輸入密碼。
2. 輸入完整晶片序號、SKU、顏色及容量代碼。
3. 指定新的簽章輸出檔，再按「建立簽章」。輸出是 64-byte 原始 ECDSA `r||s` 資料。

序號必須由實際 ATSHA204A 的 Config zone 讀取。SKU 與容量代碼需使用可列印 ASCII，不能包含空白；顏色使用 `K`、`C`、`M` 或 `Y`。輸出只是簽章檔案，程式不會讀取晶片，也不會寫入 OTP。

### 驗證簽章

1. 選取受信任公鑰資料夾，其中需有 `key-XX.pem`。
2. 輸入簽署時相同的金鑰 ID、序號、SKU、顏色和容量代碼。
3. 選取 64-byte 簽章檔並按「驗證簽章」。只有狀態顯示「驗證簽章成功」才代表該筆靜態簽章有效。

公鑰資料夾必須由機台或操作人員信任；不可使用碳粉匣自行提供的公鑰。看到「狀態：驗證簽章 成功」代表靜態簽章有效。此驗章不能取代 ATSHA204A 的即時 MAC 驗證，也不能單獨證明簽章晶片仍安裝在該碳粉匣上。

### 測試

「測試」頁執行內附的 26 項檢查。打包版使用已編譯的測試程式，不會在使用者電腦上重新編譯。

## 重要限制

這是開發與流程示範工具，不是量產簽發設備。正式產線版本仍須使用 HSM 保管不可匯出的簽章私鑰，並整合晶片序號讀取、OTP 容量與鎖定狀態確認、燒錄、回讀驗證和簽發稽核。PS2EXE 只把 PowerShell GUI 封裝成 Windows 執行檔，不會加密或保護內含程式碼。

## 開發者重建

先依 [README](README.md) 安裝 Visual Studio 2022 C++ Build Tools、CMake、vcpkg 與 OpenSSL，並安裝 Windows PowerShell 5.1 可用的 `ps2exe` 模組。接著在 repo 根目錄執行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build_gui_exe.ps1
```

執行檔會產生於 `dist\TonerSerialSignature.exe`。若要覆蓋既有輸出，明確加上 `-Force`。打包腳本會將 C 工具、Windows C runtime 與第三方授權一併嵌入單一 EXE。
