# 碳粉匣序號簽章：C 參考程式與 Windows 測試

這是以 ECDSA P-256/SHA-256 簽署 ATSHA204A 碳粉匣標準化紀錄的開發參考程式。專案包含三支命令列 C 程式（`keygen`、`sign`、`verify`）、共用的紀錄編碼器、固定的黃金測試向量，以及可在 Windows 原生執行的測試腳本。程式**不會燒錄晶片，也未整合至印表機韌體**。

## 在 Windows 執行

先安裝 Visual Studio 2022 C++ Build Tools（含 MSVC 與 CMake）、vcpkg，以及 PowerShell 5.1 或更新版本。首次透過 vcpkg 安裝 OpenSSL 時需能連線。腳本會自動尋找 Visual Studio 隨附的 vcpkg；若使用獨立安裝版本，可指定 `-VcpkgRoot`。

```powershell
pwsh -File .\run_tests.ps1
# 或使用 Windows PowerShell：
powershell.exe -NoProfile -File .\run_tests.ps1
# 使用獨立安裝的 vcpkg：
pwsh -File .\run_tests.ps1 -VcpkgRoot C:\vcpkg
```

腳本透過 CMake/vcpkg，以 MSVC 和 OpenSSL 編譯 C 程式，再執行 26 項檢查。測試用的加密金鑰會建立在作業系統暫存目錄，測試結束後即移除。看到 `RESULT: 26 passed, 0 failed` 即代表全部通過。每次推送或提交 pull request 時，GitHub Actions 也會在 `windows-2022` 執行同一腳本。專案另附適用於 POSIX 環境的 `run_tests.sh`。

## 簽署紀錄與信任模型

簽署紀錄的位元組格式固定為：`"TONER-AUTH"`（10 個 ASCII bytes，不含 NUL）｜版本 `0x02`｜金鑰 ID（1 byte，不得為零）｜晶片型號 `0x01`（ATSHA204A）｜SKU 長度與 SKU｜顏色（`K/C/M/Y`）｜容量代碼長度與容量代碼｜完整的 9-byte 二進位晶片序號。`sign` 與 `verify` 共用 `record.c` 編碼；`record_test.c` 保存固定的紀錄與 SHA-256 黃金測試向量。簽章為 64-byte 原始格式 `r[32] || s[32]`，不是 DER 格式。

驗章時，金鑰 ID 只能選取一把機台本地信任的公鑰；此命令列範例以 `TRUSTED_KEY_DIR/key-XX.pem` 模擬公鑰表。不可接受碳粉匣自行提供的公鑰。量產韌體必須內建受信任的公鑰表、從**現場晶片的 Config zone**讀取序號，並另外執行帶有新鮮挑戰的 ATSHA204A MAC 驗證。簽章失敗時，不得靜默退回較弱的驗證路徑。

`keygen.c` 與 `sign.c` 使用加密 PEM，僅供測試。量產簽發應在 HSM 中保管不可匯出的私鑰，並建立受控的簽發流程。靜態簽章本身無法防止晶片模擬、即時轉送或韌體遭修改。本範例不宣稱通過 NIST/FIPS 認證；Windows 測試通過也不能取代目標 BSP、實際碳粉匣與產線驗證。
