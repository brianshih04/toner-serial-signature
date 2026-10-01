# Package the GUI plus its native helpers into one x64 Windows executable.
[CmdletBinding()]
param(
    [string]$OutputFile = '',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw '請使用 Windows PowerShell 5.1 執行本打包腳本。'
}
if (-not $OutputFile) { $OutputFile = Join-Path $PSScriptRoot 'dist\TonerSerialSignature.exe' }

$packager = Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue
if (-not $packager) {
    throw '找不到 PS2EXE。請先在 Windows PowerShell 5.1 安裝 ps2exe 模組。'
}

$releaseDirectory = Join-Path $PSScriptRoot 'build\windows\Release'
$requiredFiles = @(
    (Join-Path $releaseDirectory 'keygen.exe'),
    (Join-Path $releaseDirectory 'sign.exe'),
    (Join-Path $releaseDirectory 'verify.exe'),
    (Join-Path $releaseDirectory 'record_test.exe'),
    (Join-Path $PSScriptRoot 'run_tests.ps1'),
    (Join-Path $PSScriptRoot 'toner_gui.ps1'),
    (Join-Path $PSScriptRoot 'PS2EXE-LICENSE.txt'),
    (Join-Path $PSScriptRoot 'build\windows\vcpkg_installed\x64-windows-static-md\share\openssl\copyright')
)
foreach ($file in $requiredFiles) {
    if (-not [IO.File]::Exists($file)) {
        throw "缺少 $file。請先依 README 編譯 Windows C 程式。"
    }
}

$programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
$vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not [IO.File]::Exists($vswhere)) { throw '找不到 Visual Studio 的 vswhere.exe。' }
$vsInstall = (& $vswhere -latest -products '*' -property installationPath | Select-Object -First 1)
if (-not $vsInstall) { throw '找不到 Visual Studio 安裝路徑。' }
$redistRoot = Join-Path $vsInstall 'VC\Redist\MSVC'
$runtime = $null
$redistVersions = Get-ChildItem -LiteralPath $redistRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending
foreach ($version in $redistVersions) {
    $candidate = Join-Path $version.FullName 'x64\Microsoft.VC143.CRT\vcruntime140.dll'
    if ([IO.File]::Exists($candidate)) { $runtime = $candidate; break }
}
if (-not $runtime) { throw '找不到 x64 VCRUNTIME140.dll，請安裝 Visual Studio C++ Build Tools。' }

$outputFull = [IO.Path]::GetFullPath($OutputFile)
if ([IO.File]::Exists($outputFull) -and -not $Force) {
    throw "輸出檔已存在：$outputFull。若要取代，請加上 -Force。"
}
$outputDirectory = [IO.Path]::GetDirectoryName($outputFull)
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$payload = '%LOCALAPPDATA%\TonerSerialSignature'
$embeddedFiles = @{
    "$payload\run_tests.ps1" = (Join-Path $PSScriptRoot 'run_tests.ps1')
    "$payload\build\windows\Release\keygen.exe" = (Join-Path $releaseDirectory 'keygen.exe')
    "$payload\build\windows\Release\sign.exe" = (Join-Path $releaseDirectory 'sign.exe')
    "$payload\build\windows\Release\verify.exe" = (Join-Path $releaseDirectory 'verify.exe')
    "$payload\build\windows\Release\record_test.exe" = (Join-Path $releaseDirectory 'record_test.exe')
    "$payload\build\windows\Release\vcruntime140.dll" = $runtime
    "$payload\licenses\OPENSSL-LICENSE.txt" = $requiredFiles[7]
    "$payload\licenses\PS2EXE-LICENSE.txt" = (Join-Path $PSScriptRoot 'PS2EXE-LICENSE.txt')
}

Import-Module ps2exe -ErrorAction Stop
Invoke-PS2EXE -inputFile (Join-Path $PSScriptRoot 'toner_gui.ps1') `
    -outputFile $outputFull -embedFiles $embeddedFiles -STA -x64 -noConsole `
    -DPIAware -supportOS -title '碳粉匣序號簽章工具' `
    -description 'ATSHA204A 簽章簽發與驗證示範工具' `
    -product 'Toner Serial Signature' -version '0.1.0.0'

if (-not [IO.File]::Exists($outputFull) -or (Get-Item -LiteralPath $outputFull).Length -lt 15MB) {
    throw '打包結果不存在或大小異常，請確認 PS2EXE 輸出。'
}
Write-Output "已建立單檔 GUI：$outputFull"
