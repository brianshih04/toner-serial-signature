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
    throw 'CMake not found. Install Visual Studio 2022 C++ Build Tools with CMake, or add cmake.exe to PATH.'
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
    throw 'vcpkg not found. Install vcpkg, then pass -VcpkgRoot C:\path\to\vcpkg.'
}

function Invoke-Checked([string]$exe, [string[]]$arguments) {
    $prior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $exe @arguments } finally { $ErrorActionPreference = $prior }
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $exe"
    }
}

function Get-TestExe([string]$name, [string]$buildDir, [string]$configuration) {
    foreach ($candidate in @(
        (Join-Path (Join-Path $buildDir $configuration) "$name.exe"),
        (Join-Path $buildDir "$name.exe")
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw "Missing $name.exe in $buildDir. Build the project first."
}

function Invoke-Case([string]$label, [int]$expected, [string]$exe, [string[]]$arguments) {
    $prior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = @(& $exe @arguments 2>&1) } finally { $ErrorActionPreference = $prior }
    $actual = $LASTEXITCODE
    $script:LastOutput = (($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ($actual -ne $expected) {
        throw "FAIL $label`: exit=$actual expected=$expected`n$script:LastOutput"
    }
    $script:Passed++
    Write-Host "PASS $label (exit=$actual)"
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
    throw 'Refusing to use a test directory outside the OS temp folder.'
}

New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
$priorPassword = [Environment]::GetEnvironmentVariable('TONER_DEMO_KEY_PASSWORD', 'Process')
$script:Passed = 0
$script:LastOutput = ''
try {
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

    Invoke-Case 'golden vectors' 0 $recordTest @()
    Invoke-Case 'keygen 01' 0 $keygen @($private1, $public1)
    Invoke-Case 'keygen 02' 0 $keygen @($private2, $public2)
    Copy-Item -LiteralPath $public2 -Destination (Join-Path $wrongKeys 'key-01.pem')

    Invoke-Case 'sign' 0 $sign @($private1, '01', $sn, $sku, 'K', $capacity, $signature)
    Invoke-Case 'verify valid' 0 $verify @($keys, '01', $sn, $sku, 'K', $capacity, $signature)
    if ($script:LastOutput -ne 'VALID') { throw 'Verifier did not print exactly VALID.' }
    $script:Passed++
    Write-Host 'PASS stdout=VALID'

    Invoke-Case 'changed key ID' 2 $verify @($keys, '02', $sn, $sku, 'K', $capacity, $signature)
    Invoke-Case 'changed serial' 2 $verify @($keys, '01', '0123AABBCCDDEEFFEF', $sku, 'K', $capacity, $signature)
    Invoke-Case 'changed SKU' 2 $verify @($keys, '01', $sn, 'AV-TONEX', 'K', $capacity, $signature)
    Invoke-Case 'changed color' 2 $verify @($keys, '01', $sn, $sku, 'C', $capacity, $signature)
    Invoke-Case 'changed capacity' 2 $verify @($keys, '01', $sn, $sku, 'K', 'HC-9999', $signature)
    Invoke-Case 'wrong trusted key' 2 $verify @($wrongKeys, '01', $sn, $sku, 'K', $capacity, $signature)
    Invoke-Case 'unknown key ID' 2 $verify @($keys, '03', $sn, $sku, 'K', $capacity, $signature)
    Invoke-Case 'revoked key ID' 2 $verify @($revokedKeys, '01', $sn, $sku, 'K', $capacity, $signature)

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
    if ($sigBytes.Length -ne 64) { throw 'Signer did not produce exactly 64 bytes.' }
    $shortBytes = New-Object byte[] 63
    $longBytes = New-Object byte[] 65
    [Array]::Copy($sigBytes, $shortBytes, 63)
    [Array]::Copy($sigBytes, $longBytes, 64)
    [IO.File]::WriteAllBytes($short, $shortBytes)
    [IO.File]::WriteAllBytes($long, $longBytes)
    Invoke-Case 'zero signature' 2 $verify @($keys, '01', $sn, $sku, 'K', $capacity, $zero)
    Invoke-Case 'random signature' 2 $verify @($keys, '01', $sn, $sku, 'K', $capacity, $random)
    Invoke-Case '63-byte signature' 2 $verify @($keys, '01', $sn, $sku, 'K', $capacity, $short)
    Invoke-Case '65-byte signature' 2 $verify @($keys, '01', $sn, $sku, 'K', $capacity, $long)

    Invoke-Case 'short serial input' 2 $verify @($keys, '01', '0123', $sku, 'K', $capacity, $signature)
    Invoke-Case 'space in SKU' 2 $verify @($keys, '01', $sn, 'AV TONER', 'K', $capacity, $signature)
    Invoke-Case 'zero key ID' 2 $verify @($keys, '00', $sn, $sku, 'K', $capacity, $signature)
    Invoke-Case 'two-character color' 2 $verify @($keys, '01', $sn, $sku, 'KK', $capacity, $signature)
    Invoke-Case 'sign rejects zero key ID' 1 $sign @($private1, '00', $sn, $sku, 'K', $capacity, (Join-Path $work 'unused.bin'))
    Invoke-Case 'missing signature file' 1 $verify @($keys, '01', $sn, $sku, 'K', $capacity, (Join-Path $work 'missing.bin'))
    Invoke-Case 'sign refuses overwrite' 1 $sign @($private1, '01', $sn, $sku, 'K', $capacity, $signature)
    Invoke-Case 'keygen refuses overwrite' 1 $keygen @($private1, (Join-Path $work 'k3.pub'))

    if ($script:Passed -ne 26) { throw "Expected 26 checks; completed $script:Passed." }
    Write-Host "RESULT: $script:Passed passed, 0 failed"
}
finally {
    [Environment]::SetEnvironmentVariable('TONER_DEMO_KEY_PASSWORD', $priorPassword, 'Process')
    # The path was validated above and created by this invocation only.
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
