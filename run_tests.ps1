# Native Windows build and functional validation for the C reference code.
# Prerequisites: Visual Studio 2022 C++ Build Tools, CMake, vcpkg, network
# access for vcpkg's first OpenSSL installation, and PowerShell 5.1+.
[CmdletBinding()]
param(
    [string]$BuildDir = '',
    [string]$VcpkgRoot = '',
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $BuildDir) { $BuildDir = Join-Path $PSScriptRoot 'build\windows' }

function Get-VSInstall {
    $pf86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { return $null }
    $result = & $vswhere -latest -products '*' -property installationPath
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($result | Select-Object -First 1)
}

function Get-CMakePath([string]$vsInstall) {
    $command = Get-Command cmake.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    if ($vsInstall) {
        $candidate = Join-Path $vsInstall 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw '找不到 CMake。請安裝含 CMake 的 Visual Studio 2022 C++ Build Tools，或將 cmake.exe 加入 PATH。'
}

function Get-VcpkgRoot([string]$explicit, [string]$vsInstall) {
    $candidates = @($explicit, $env:VCPKG_ROOT, $env:VCPKG_INSTALLATION_ROOT)
    if ($vsInstall) { $candidates += (Join-Path $vsInstall 'VC\vcpkg') }
    $candidates += 'C:\vcpkg'
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $toolchain = Join-Path $candidate 'scripts\buildsystems\vcpkg.cmake'
        if (Test-Path -LiteralPath $toolchain) { return [IO.Path]::GetFullPath($candidate) }
    }
    throw '找不到 vcpkg。請先安裝 vcpkg，再以 -VcpkgRoot 指定其目錄。'
}

function Invoke-Checked([string]$exe, [string[]]$arguments) {
    $prior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $exe @arguments } finally { $ErrorActionPreference = $prior }
    if ($LASTEXITCODE -ne 0) {
        throw "命令執行失敗（退出碼 $LASTEXITCODE）：$exe"
    }
}

function Get-TestExe([string]$name, [string]$buildDir, [string]$configuration) {
    foreach ($candidate in @(
        (Join-Path (Join-Path $buildDir $configuration) "$name.exe"),
        (Join-Path $buildDir "$name.exe")
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw "在 $buildDir 找不到 $name.exe；請先編譯專案。"
}

function Invoke-Case([string]$label, [int]$expected, [string]$exe, [string[]]$arguments) {
    $prior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = @(& $exe @arguments 2>&1) } finally { $ErrorActionPreference = $prior }
    $actual = $LASTEXITCODE
    $script:LastOutput = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ($actual -ne $expected) {
        throw "失敗：$label；實際退出碼 $actual，預期 $expected`n$script:LastOutput"
    }
    $script:Passed++
    Write-Host "通過：$label（退出碼 $actual）"
}

$buildFull = [IO.Path]::GetFullPath($BuildDir)
if (-not $SkipBuild) {
    $vsInstall = Get-VSInstall
    $cmake = Get-CMakePath $vsInstall
    $vcpkg = Get-VcpkgRoot $VcpkgRoot $vsInstall
    $toolchain = Join-Path $vcpkg 'scripts\buildsystems\vcpkg.cmake'
    New-Item -ItemType Directory -Path $buildFull -Force | Out-Null
    if (-not $env:VCPKG_DOWNLOADS) {
        $env:VCPKG_DOWNLOADS = Join-Path $buildFull 'vcpkg-downloads'
    }
    New-Item -ItemType Directory -Path $env:VCPKG_DOWNLOADS -Force | Out-Null
    Invoke-Checked $cmake @(
        '-S', $PSScriptRoot, '-B', $buildFull,
        '-G', 'Visual Studio 17 2022', '-A', 'x64',
        "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
        '-DVCPKG_TARGET_TRIPLET=x64-windows-static-md',
        '-DOPENSSL_USE_STATIC_LIBS=ON'
    )
    Invoke-Checked $cmake @('--build', $buildFull, '--config', $Configuration, '--parallel')
}

$keygen = Get-TestExe 'keygen' $buildFull $Configuration
$sign = Get-TestExe 'sign' $buildFull $Configuration
$verify = Get-TestExe 'verify' $buildFull $Configuration
$recordTest = Get-TestExe 'record_test' $buildFull $Configuration

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$leaf = 'toner-auth-test-' + [Guid]::NewGuid().ToString('N')
$work = [IO.Path]::GetFullPath((Join-Path $tempRoot $leaf))
if (-not $tempRoot.EndsWith([IO.Path]::DirectorySeparatorChar.ToString())) {
    $tempRoot += [IO.Path]::DirectorySeparatorChar
}
if (-not $work.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetFileName($work) -ne $leaf) {
    throw '測試目錄不在作業系統暫存目錄內，已停止執行。'
}

New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
$priorPassword = [Environment]::GetEnvironmentVariable('TONER_DEMO_KEY_PASSWORD', 'Process')
$priorConsoleEncoding = [Console]::OutputEncoding
$script:Passed = 0
$script:LastOutput = ''
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $secret = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($secret) } finally { $rng.Dispose() }
    $env:TONER_DEMO_KEY_PASSWORD = [Convert]::ToBase64String($secret)
    [Array]::Clear($secret, 0, $secret.Length)

    $keys = Join-Path $work 'keys'
    $wrongKeys = Join-Path $work 'wrong-keys'
    $revokedKeys = Join-Path $work 'revoked-keys'
    foreach ($dir in @($keys, $wrongKeys, $revokedKeys)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    $private1 = Join-Path $work 'k1.priv'
    $private2 = Join-Path $work 'k2.priv'
    $public1 = Join-Path $keys 'key-01.pem'
    $public2 = Join-Path $keys 'key-02.pem'
    $signature = Join-Path $work 'sig.bin'
    $sn = '0123AABBCCDDEEFFEE'
    $sku = 'AV-TONER'
    $capacity = 'HC-6500'

    Invoke-Case '黃金測試向量' 0 $recordTest @()
    Invoke-Case '產生金鑰 01' 0 $keygen @($private1, $public1)
    Invoke-Case '產生金鑰 02' 0 $keygen @($private2, $public2)
    Copy-Item -LiteralPath $public2 -Destination (Join-Path $wrongKeys 'key-01.pem')

    Invoke-Case '建立簽章' 0 $sign @($private1, '01', $sn, $sku, 'K', $capacity, $signature)
    Invoke-Case '有效簽章驗證' 0 $verify @($keys, '01', $sn, $sku, 'K', $capacity, $signature)
    if ($script:LastOutput -ne '驗證通過') { throw '驗章程式未輸出「驗證通過」。' }
    $script:Passed++
    Write-Host '通過：驗章輸出為「驗證通過」'

    Invoke-Case '變更金鑰 ID' 2 $verify @($keys, '02', $sn, $sku, 'K', $capacity, $signature)
    Invoke-Case '變更晶片序號' 2 $verify @($keys, '01', '0123AABBCCDDEEFFEF', $sku, 'K', $capacity, $signature)
    Invoke-Case '變更 SKU' 2 $verify @($keys, '01', $sn, 'AV-TONEX', 'K', $capacity, $signature)
    Invoke-Case '變更顏色' 2 $verify @($keys, '01', $sn, $sku, 'C', $capacity, $signature)
    Invoke-Case '變更容量' 2 $verify @($keys, '01', $sn, $sku, 'K', 'HC-9999', $signature)
    Invoke-Case '錯誤的受信任公鑰' 2 $verify @($wrongKeys, '01', $sn, $sku, 'K', $capacity, $signature)
    Invoke-Case '未知的金鑰 ID' 2 $verify @($keys, '03', $sn, $sku, 'K', $capacity, $signature)
    Invoke-Case '已撤銷的金鑰 ID' 2 $verify @($revokedKeys, '01', $sn, $sku, 'K', $capacity, $signature)

    $zero = Join-Path $work 'zero.bin'
    $random = Join-Path $work 'random.bin'
    $short = Join-Path $work 'short.bin'
    $long = Join-Path $work 'long.bin'
    [IO.File]::WriteAllBytes($zero, (New-Object byte[] 64))
    $randomBytes = New-Object byte[] 64
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($randomBytes) } finally { $rng.Dispose() }
    [IO.File]::WriteAllBytes($random, $randomBytes)
    $sigBytes = [IO.File]::ReadAllBytes($signature)
    if ($sigBytes.Length -ne 64) { throw '簽章程式未產生恰好 64 位元組的簽章。' }
    $shortBytes = New-Object byte[] 63
    $longBytes = New-Object byte[] 65
    [Array]::Copy($sigBytes, $shortBytes, 63)
    [Array]::Copy($sigBytes, $longBytes, 64)
    [IO.File]::WriteAllBytes($short, $shortBytes)
    [IO.File]::WriteAllBytes($long, $longBytes)
    Invoke-Case '全零簽章' 2 $verify @($keys, '01', $sn, $sku, 'K', $capacity, $zero)
    Invoke-Case '隨機簽章' 2 $verify @($keys, '01', $sn, $sku, 'K', $capacity, $random)
    Invoke-Case '63 位元組簽章' 2 $verify @($keys, '01', $sn, $sku, 'K', $capacity, $short)
    Invoke-Case '65 位元組簽章' 2 $verify @($keys, '01', $sn, $sku, 'K', $capacity, $long)

    Invoke-Case '序號長度不足' 2 $verify @($keys, '01', '0123', $sku, 'K', $capacity, $signature)
    Invoke-Case 'SKU 含空白' 2 $verify @($keys, '01', $sn, 'AV TONER', 'K', $capacity, $signature)
    Invoke-Case '金鑰 ID 為零' 2 $verify @($keys, '00', $sn, $sku, 'K', $capacity, $signature)
    Invoke-Case '顏色欄位長度錯誤' 2 $verify @($keys, '01', $sn, $sku, 'KK', $capacity, $signature)
    Invoke-Case '簽章程式拒絕零金鑰 ID' 1 $sign @($private1, '00', $sn, $sku, 'K', $capacity, (Join-Path $work 'unused.bin'))
    Invoke-Case '簽章檔案不存在' 1 $verify @($keys, '01', $sn, $sku, 'K', $capacity, (Join-Path $work 'missing.bin'))
    Invoke-Case '簽章程式拒絕覆寫' 1 $sign @($private1, '01', $sn, $sku, 'K', $capacity, $signature)
    Invoke-Case '金鑰程式拒絕覆寫' 1 $keygen @($private1, (Join-Path $work 'k3.pub'))

    if ($script:Passed -ne 26) { throw "預期執行 26 項檢查，實際完成 $script:Passed 項。" }
    Write-Host "結果：$script:Passed 項通過，0 項失敗"
}
finally {
    [Environment]::SetEnvironmentVariable('TONER_DEMO_KEY_PASSWORD', $priorPassword, 'Process')
    [Console]::OutputEncoding = $priorConsoleEncoding
    # The path was validated above and created by this invocation only.
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
# The last negative test deliberately returns 1. GitHub's pwsh wrapper
# propagates LASTEXITCODE even when the suite itself completed successfully.
$global:LASTEXITCODE = 0
