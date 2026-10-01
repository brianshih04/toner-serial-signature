# Windows 簽章示範介面；保留 CLI，不連接 HSM、晶片讀取器或 OTP 燒錄器。
[CmdletBinding()]
param([switch]$SelfTest, [switch]$SelfTestFlow)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$script:process = $null
$script:stdoutTask = $null
$script:stderrTask = $null
$script:action = ''
$script:outputs = @()
$script:cancelled = $false
$script:flowStage = 0
$script:flowSuccess = $false
$script:flowFailure = ''
$script:flowRoot = $null
$script:flowPassword = ''

function Remove-Temporary([string]$path, [string]$prefix) {
    if (-not $path) { return }
    $root = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $root.EndsWith([IO.Path]::DirectorySeparatorChar.ToString())) {
        $root += [IO.Path]::DirectorySeparatorChar
    }
    $target = [IO.Path]::GetFullPath($path)
    if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($target) -notmatch ('^' + [regex]::Escape($prefix) + '[0-9a-f]{32}$')) {
        throw '拒絕清除不在安全暫存範圍內的目錄。'
    }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
}

function Close-ProcessResources {
    if ($script:process) { $script:process.Dispose(); $script:process = $null }
    $script:stdoutTask = $null
    $script:stderrTask = $null
}

function Quote-Argument([string]$value) {
    $quoted = '"'
    $slashes = 0
    foreach ($character in $value.ToCharArray()) {
        if ($character -eq '\') { $slashes++ }
        elseif ($character -eq '"') {
            $quoted += ('\' * (2 * $slashes + 1)) + '"'
            $slashes = 0
        } else {
            $quoted += ('\' * $slashes) + $character
            $slashes = 0
        }
    }
    return $quoted + ('\' * (2 * $slashes)) + '"'
}

function Get-Program([string]$name) {
    foreach ($candidate in @(
        (Join-Path $PSScriptRoot "build\windows\Release\$name.exe"),
        (Join-Path $PSScriptRoot "build\windows\$name.exe")
    )) {
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    throw "找不到 $name.exe；請先在「測試」頁執行編譯。"
}

function Assert-File([string]$path, [string]$label) {
    if (-not [IO.File]::Exists($path)) { throw "找不到$label。" }
}

function Assert-Folder([string]$path, [string]$label) {
    if (-not [IO.Directory]::Exists($path)) { throw "找不到$label。" }
}

function Assert-NewFile([string]$path, [string]$label) {
    if (-not $path) { throw "請選擇$label。" }
    Assert-Folder ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path))) '輸出資料夾'
    if (Test-Path -LiteralPath $path) { throw "$label 已存在；為避免覆寫，請改用新檔名。" }
}

function Assert-KeyId([string]$value) {
    $value = $value.Trim().ToUpperInvariant()
    if ($value -notmatch '^[0-9A-F]{2}$' -or $value -eq '00') {
        throw '金鑰 ID 須為 01 至 FF 的兩位十六進位值。'
    }
    return $value
}

function Get-RecordFields($id, $sn, $sku, $color, $capacity) {
    $id = Assert-KeyId $id
    $sn = $sn.Trim().ToUpperInvariant()
    $color = $color.Trim().ToUpperInvariant()
    if ($sn -notmatch '^[0-9A-F]{18}$') { throw '晶片序號須為完整 9-byte（18 位十六進位字元）。' }
    if ($sku.Length -lt 1 -or $sku.Length -gt 64 -or $sku -notmatch '^[\x21-\x7e]+$') {
        throw 'SKU 須為 1–64 個不含空白的 ASCII 字元。'
    }
    if ($capacity.Length -lt 1 -or $capacity.Length -gt 32 -or $capacity -notmatch '^[\x21-\x7e]+$') {
        throw '容量代碼須為 1–32 個不含空白的 ASCII 字元。'
    }
    if ($color -notin @('K', 'C', 'M', 'Y')) { throw '顏色須為 K、C、M 或 Y。' }
    return @($id, $sn, $sku, $color, $capacity)
}

function Assert-Password([string]$value) {
    if ($value.Length -lt 16 -or $value.Length -gt 1024 -or $value -notmatch '^[\x21-\x7e]+$') {
        throw '測試私鑰密碼須為 16–1024 個不含空白的 ASCII 字元。'
    }
}

$form = New-Object Windows.Forms.Form
$form.Text = '碳粉匣序號簽章工具（示範）'
$form.ClientSize = [Drawing.Size]::new(980, 850)
$form.MinimumSize = [Drawing.Size]::new(940, 750)
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = 'Dpi'
$form.Font = [Drawing.Font]::new('Microsoft JhengHei UI', 10)

$title = New-Object Windows.Forms.Label
$title.Text = '碳粉匣序號簽章工具'
$title.Font = [Drawing.Font]::new('Microsoft JhengHei UI', 16, [Drawing.FontStyle]::Bold)
$title.SetBounds(24, 15, 900, 39)
$title.Anchor = 'Top,Left,Right'
$form.Controls.Add($title)

$warning = New-Object Windows.Forms.Label
$warning.Text = '示範工具：未整合 HSM、晶片讀取或 OTP 燒錄；不可直接作為量產安全設備。CLI 仍可獨立使用。'
$warning.SetBounds(24, 55, 900, 32)
$warning.Anchor = 'Top,Left,Right'
$form.Controls.Add($warning)

$tabs = New-Object Windows.Forms.TabControl
$tabs.SetBounds(24, 95, 932, 455)
$tabs.Anchor = 'Top,Left,Right'
$form.Controls.Add($tabs)
foreach ($name in @('測試', '產生測試金鑰', '工廠簽發（示範）', '驗證簽章')) {
    $tab = New-Object Windows.Forms.TabPage
    $tab.Text = $name
    [void]$tabs.TabPages.Add($tab)
}
$testTab = $tabs.TabPages[0]
$keyTab = $tabs.TabPages[1]
$signTab = $tabs.TabPages[2]
$verifyTab = $tabs.TabPages[3]

function Add-Row($tab, [string]$label, [int]$y, [string]$browse = '',
                 [bool]$secret = $false, [string]$default = '') {
    $caption = New-Object Windows.Forms.Label
    $caption.Text = $label
    $caption.SetBounds(16, $y + 5, 140, 27)
    $tab.Controls.Add($caption)
    $box = New-Object Windows.Forms.TextBox
    $box.SetBounds(160, $y, $(if ($browse) { 608 } else { 735 }), 29)
    $box.Anchor = 'Top,Left,Right'
    $box.Text = $default
    $box.UseSystemPasswordChar = $secret
    $tab.Controls.Add($box)
    if ($browse) {
        $button = New-Object Windows.Forms.Button
        $button.Text = '瀏覽…'
        $button.SetBounds(783, $y - 1, 112, 31)
        $button.Anchor = 'Top,Right'
        $tab.Controls.Add($button)
        $button.Add_Click({
            if ($browse -eq 'Folder') {
                $dialog = New-Object Windows.Forms.FolderBrowserDialog
                $dialog.Description = "選擇$label"
                if ([IO.Directory]::Exists($box.Text)) { $dialog.SelectedPath = $box.Text }
            } elseif ($browse -eq 'Save') {
                $dialog = New-Object Windows.Forms.SaveFileDialog
                $dialog.Title = "選擇$label"
                $dialog.OverwritePrompt = $false
            } else {
                $dialog = New-Object Windows.Forms.OpenFileDialog
                $dialog.Title = "選擇$label"
            }
            if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
                if ($browse -eq 'Folder') { $box.Text = $dialog.SelectedPath }
                else { $box.Text = $dialog.FileName }
            }
            $dialog.Dispose()
        }.GetNewClosure())
    }
    return $box
}

function Add-Note($tab, [string]$message, [int]$y) {
    $note = New-Object Windows.Forms.Label
    $note.Text = $message
    $note.SetBounds(16, $y, 880, 48)
    $note.Anchor = 'Top,Left,Right'
    $note.ForeColor = [Drawing.Color]::FromArgb(88, 70, 42)
    $tab.Controls.Add($note)
}

function Add-Button($tab, [string]$caption, [int]$y) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $caption
    $button.SetBounds(748, $y, 147, 36)
    $button.Anchor = 'Top,Right'
    $tab.Controls.Add($button)
    return $button
}

Add-Note $testTab '以 MSVC 和 OpenSSL 編譯 C 程式，並執行 26 項正反向檢查。首次執行請參考 README 安裝編譯工具。' 32
$skipBuild = New-Object Windows.Forms.CheckBox
$skipBuild.Text = '只執行測試（略過編譯）'
$skipBuild.SetBounds(24, 105, 350, 32)
$testTab.Controls.Add($skipBuild)
$testButton = Add-Button $testTab '開始編譯與測試' 101

$keyId = Add-Row $keyTab '金鑰 ID（01–FF）' 16 '' $false '01'
$privateFile = Add-Row $keyTab '加密私鑰檔案' 59 'Save'
$publicFolder = Add-Row $keyTab '公鑰輸出資料夾' 102 'Folder'
$keyPass = Add-Row $keyTab '測試私鑰密碼' 145 '' $true
$keyPassAgain = Add-Row $keyTab '再次輸入密碼' 188 '' $true
$keyButton = Add-Button $keyTab '產生測試金鑰' 245
Add-Note $keyTab '公鑰命名為 key-XX.pem；私鑰以加密 PEM 儲存，不覆寫既有檔案。量產私鑰應由 HSM 產生並保管。' 305

$signPrivate = Add-Row $signTab '加密私鑰檔案' 7 'Open'
$signId = Add-Row $signTab '金鑰 ID（01–FF）' 48 '' $false '01'
$signSn = Add-Row $signTab '晶片序號（18 hex）' 89
$signSku = Add-Row $signTab 'SKU' 130
$signColor = Add-Row $signTab '顏色（K/C/M/Y）' 171 '' $false 'K'
$signCapacity = Add-Row $signTab '容量代碼' 212
$signatureFile = Add-Row $signTab '64-byte 簽章檔案' 253 'Save'
$signPass = Add-Row $signTab '測試私鑰密碼' 294 '' $true
$signButton = Add-Button $signTab '建立簽章' 336
Add-Note $signTab '序號應取自實際晶片 Config zone，不可取自匣上可改寫資料。此頁只產生檔案，不會寫入 OTP。' 374

$verifyFolder = Add-Row $verifyTab '受信任公鑰資料夾' 15 'Folder'
$verifyId = Add-Row $verifyTab '金鑰 ID（01–FF）' 58 '' $false '01'
$verifySn = Add-Row $verifyTab '晶片序號（18 hex）' 101
$verifySku = Add-Row $verifyTab 'SKU' 144
$verifyColor = Add-Row $verifyTab '顏色（K/C/M/Y）' 187 '' $false 'K'
$verifyCapacity = Add-Row $verifyTab '容量代碼' 230
$verifyFile = Add-Row $verifyTab '64-byte 簽章檔案' 273 'Open'
$verifyButton = Add-Button $verifyTab '驗證簽章' 326
Add-Note $verifyTab '僅從受信任資料夾選取 key-XX.pem。簽章通過不等於已完成 ATSHA204A 的即時 MAC 驗證。' 372

$status = New-Object Windows.Forms.Label
$status.Text = '狀態：尚未執行'
$status.SetBounds(24, 564, 790, 30)
$status.Anchor = 'Top,Left,Right'
$form.Controls.Add($status)
$cancel = New-Object Windows.Forms.Button
$cancel.Text = '取消作業'
$cancel.SetBounds(850, 559, 106, 36)
$cancel.Anchor = 'Top,Right'
$cancel.Enabled = $false
$form.Controls.Add($cancel)
$progress = New-Object Windows.Forms.ProgressBar
$progress.SetBounds(24, 605, 932, 12)
$progress.Anchor = 'Top,Left,Right'
$progress.Style = 'Marquee'
$progress.MarqueeAnimationSpeed = 25
$progress.Visible = $false
$form.Controls.Add($progress)
$log = New-Object Windows.Forms.RichTextBox
$log.SetBounds(24, 628, 932, 196)
$log.Anchor = 'Top,Bottom,Left,Right'
$log.Font = [Drawing.Font]::new('Consolas', 9)
$log.ReadOnly = $true
$log.WordWrap = $false
$log.ScrollBars = 'Both'
$form.Controls.Add($log)

function Append-Log([string]$message) {
    if (-not $message) { return }
    $log.AppendText($message)
    $log.SelectionStart = $log.TextLength
    $log.ScrollToCaret()
}

function Start-Job([string]$kind, [string]$program, [string[]]$arguments,
                   [string]$password = '', [string[]]$outputs = @()) {
    $script:action = $kind
    $script:outputs = $outputs
    $script:cancelled = $false
    $log.Clear()
    $status.Text = "狀態：$kind 執行中…"
    $status.ForeColor = [Drawing.Color]::DarkBlue
    $progress.Visible = $true
    $tabs.Enabled = $false
    $cancel.Enabled = $true
    $line = ($arguments | ForEach-Object { Quote-Argument $_ }) -join ' '
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $program
    $info.Arguments = $line
    $info.WorkingDirectory = $PSScriptRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    if ($password) { $info.EnvironmentVariables['TONER_DEMO_KEY_PASSWORD'] = $password }
    else { $info.EnvironmentVariables.Remove('TONER_DEMO_KEY_PASSWORD') }
    $script:process = [Diagnostics.Process]::new()
    $script:process.StartInfo = $info
    if (-not $script:process.Start()) { throw "無法啟動 $program。" }
    $script:stdoutTask = $script:process.StandardOutput.ReadToEndAsync()
    $script:stderrTask = $script:process.StandardError.ReadToEndAsync()
    $timer.Start()
}

function Start-Error([string]$message) {
    if ($script:process -and -not $script:process.HasExited) {
        & taskkill.exe /PID $script:process.Id /T /F 2>&1 | Out-Null
    }
    $progress.Visible = $false
    $tabs.Enabled = $true
    $cancel.Enabled = $false
    $status.Text = '狀態：無法啟動作業'
    $status.ForeColor = [Drawing.Color]::DarkRed
    Append-Log ("錯誤：$message`r`n")
    $script:flowFailure = $message
    Close-ProcessResources
    if ($SelfTestFlow) { $form.Close() }
}

$testButton.Add_Click({
    try {
        $runner = Join-Path $PSScriptRoot 'run_tests.ps1'
        Assert-File $runner '測試腳本'
        $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner)
        if ($skipBuild.Checked) { $args += '-SkipBuild' }
        Start-Job '測試' $shell $args
    } catch { Start-Error $_.Exception.Message }
})

$keyButton.Add_Click({
    try {
        $id = Assert-KeyId $keyId.Text
        Assert-Folder $publicFolder.Text '公鑰輸出資料夾'
        $public = Join-Path $publicFolder.Text "key-$id.pem"
        Assert-NewFile $privateFile.Text '加密私鑰檔案'
        Assert-NewFile $public '公鑰檔案'
        Assert-Password $keyPass.Text
        if ($keyPass.Text -cne $keyPassAgain.Text) { throw '兩次輸入的密碼不同。' }
        Start-Job '產生測試金鑰' (Get-Program 'keygen') `
            @($privateFile.Text, $public) $keyPass.Text @($privateFile.Text, $public)
    } catch { Start-Error $_.Exception.Message }
})

$signButton.Add_Click({
    try {
        Assert-File $signPrivate.Text '加密私鑰檔案'
        $fields = Get-RecordFields $signId.Text $signSn.Text $signSku.Text $signColor.Text $signCapacity.Text
        Assert-NewFile $signatureFile.Text '簽章檔案'
        if (-not $signPass.Text) { throw '請輸入測試私鑰密碼。' }
        Start-Job '建立簽章' (Get-Program 'sign') `
            (@($signPrivate.Text) + $fields + @($signatureFile.Text)) $signPass.Text @($signatureFile.Text)
    } catch { Start-Error $_.Exception.Message }
})

$verifyButton.Add_Click({
    try {
        Assert-Folder $verifyFolder.Text '受信任公鑰資料夾'
        $fields = Get-RecordFields $verifyId.Text $verifySn.Text $verifySku.Text $verifyColor.Text $verifyCapacity.Text
        Assert-File $verifyFile.Text '簽章檔案'
        Start-Job '驗證簽章' (Get-Program 'verify') `
            (@($verifyFolder.Text) + $fields + @($verifyFile.Text))
    } catch { Start-Error $_.Exception.Message }
})

function Continue-Flow {
    if (-not $SelfTestFlow) { return }
    if ($script:flowStage -eq 1) {
        $script:flowStage = 2
        $signPass.Text = $script:flowPassword
        $tabs.SelectedTab = $signTab
        $signButton.PerformClick()
    } elseif ($script:flowStage -eq 2) {
        $script:flowStage = 3
        $tabs.SelectedTab = $verifyTab
        $verifyButton.PerformClick()
    } elseif ($script:flowStage -eq 3) {
        $script:flowStage = 4
        $tabs.SelectedTab = $testTab
        $skipBuild.Checked = $true
        $testButton.PerformClick()
    } else {
        $script:flowSuccess = $true
        $form.Close()
    }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
    try {
        if ($script:process -and $script:process.HasExited) {
            $timer.Stop()
            $script:process.WaitForExit()
            Append-Log $script:stdoutTask.GetAwaiter().GetResult()
            Append-Log $script:stderrTask.GetAwaiter().GetResult()
            $code = $script:process.ExitCode
            $kind = $script:action
            $ok = $code -eq 0
            if ($kind -eq '測試') {
                $ok = $ok -and $log.Text.Contains('結果：26 項通過，0 項失敗')
            } elseif ($kind -eq '產生測試金鑰') {
                $ok = $ok -and [IO.File]::Exists($script:outputs[0]) -and [IO.File]::Exists($script:outputs[1])
            } elseif ($kind -eq '建立簽章') {
                $ok = $ok -and [IO.File]::Exists($script:outputs[0])
                if ($ok) { $ok = ([IO.FileInfo]::new($script:outputs[0])).Length -eq 64 }
            } elseif ($kind -eq '驗證簽章') {
                $ok = $ok -and $log.Text.Contains('驗證通過')
            }
            $progress.Visible = $false
            $tabs.Enabled = $true
            $cancel.Enabled = $false
            if ($script:cancelled) {
                $status.Text = '狀態：已取消'
                $status.ForeColor = [Drawing.Color]::DarkOrange
            } elseif ($ok) {
                $status.Text = "狀態：$kind 成功"
                $status.ForeColor = [Drawing.Color]::DarkGreen
            } else {
                $status.Text = "狀態：$kind 失敗（退出碼 $code）"
                $status.ForeColor = [Drawing.Color]::DarkRed
            }
            $keyPass.Clear()
            $keyPassAgain.Clear()
            $signPass.Clear()
            Close-ProcessResources
            if ($SelfTestFlow) {
                if ($ok -and -not $script:cancelled) { Continue-Flow }
                else {
                    $script:flowFailure = "$kind 退出碼 $code；$($log.Text)"
                    $form.Close()
                }
            }
        }
    } catch {
        $timer.Stop()
        $progress.Visible = $false
        $tabs.Enabled = $true
        $cancel.Enabled = $false
        $status.Text = '狀態：讀取結果時發生錯誤'
        $status.ForeColor = [Drawing.Color]::DarkRed
        Append-Log ("`r`n錯誤：" + $_.Exception.Message + "`r`n")
        $script:flowFailure = $_.Exception.Message
        if ($SelfTestFlow) { $form.Close() }
    }
})

$cancel.Add_Click({
    if (-not $script:process -or $script:process.HasExited) { return }
    $answer = [Windows.Forms.MessageBox]::Show('確定要中止目前作業嗎？', '確認取消',
        [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    $script:cancelled = $true
    & taskkill.exe /PID $script:process.Id /T /F 2>&1 | Out-Null
})

$form.Add_FormClosing({
    if ($script:process -and -not $script:process.HasExited) {
        $_.Cancel = $true
        [Windows.Forms.MessageBox]::Show('作業仍在執行，請先取消或等待完成。', '請稍候') | Out-Null
    }
})

if ($SelfTest) {
    if ($tabs.TabPages.Count -ne 4 -or $signButton.Text -ne '建立簽章' -or
        (Quote-Argument 'C:\Program Files\key.pem') -ne '"C:\Program Files\key.pem"') {
        throw '圖形介面元件檢查失敗。'
    }
    $form.Dispose()
    Write-Output '圖形介面元件檢查通過'
    exit 0
}

if ($SelfTestFlow) {
    $script:flowRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'toner-gui-flow-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:flowRoot -ErrorAction Stop | Out-Null
    $keys = Join-Path $script:flowRoot 'keys with spaces 測試'
    New-Item -ItemType Directory -Path $keys -ErrorAction Stop | Out-Null
    $privateFile.Text = Join-Path $script:flowRoot '私鑰 private key.pem'
    $publicFolder.Text = $keys
    $signPrivate.Text = $privateFile.Text
    $signSn.Text = '0123AABBCCDDEEFFEE'
    $signSku.Text = 'AV-TONER'
    $signCapacity.Text = 'HC-6500'
    $signatureFile.Text = Join-Path $script:flowRoot '簽章 file.bin'
    $verifyFolder.Text = $keys
    $verifySn.Text = $signSn.Text
    $verifySku.Text = $signSku.Text
    $verifyCapacity.Text = $signCapacity.Text
    $verifyFile.Text = $signatureFile.Text
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $password = [Convert]::ToBase64String($bytes)
    $script:flowPassword = $password
    [Array]::Clear($bytes, 0, $bytes.Length)
    $keyPass.Text = $password
    $keyPassAgain.Text = $password
    $signPass.Text = $password
    $form.Opacity = 0
    $form.ShowInTaskbar = $false
    $form.Add_Shown({
        $script:flowStage = 1
        $tabs.SelectedTab = $keyTab
        $keyButton.PerformClick()
    })
}

try {
    [Windows.Forms.Application]::Run($form)
} finally {
    $script:flowStatus = $status.Text
    $script:flowLog = $log.Text
    Close-ProcessResources
    if ($script:flowRoot) { Remove-Temporary $script:flowRoot 'toner-gui-flow-' }
    $script:flowPassword = ''
    $form.Dispose()
}
if ($SelfTestFlow) {
    if (-not $script:flowSuccess) {
        throw ("圖形介面金鑰產生、簽發、驗章流程測試失敗。{0}{1}{0}{2}" -f
            [Environment]::NewLine, ("階段 {0}：{1}" -f $script:flowStage, $script:flowFailure), $script:flowLog)
    }
    Write-Output '圖形介面金鑰產生、簽發、驗章與 26 項測試流程通過'
}
