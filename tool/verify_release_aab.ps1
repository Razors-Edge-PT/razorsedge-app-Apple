# Verifies a built GoodLift release AAB (the artifact itself, not the Gradle inputs):
#   * the compiled com.goodlift.razorsedge.BuildConfig in the AAB's DEX: application id, release
#     build type, DEBUG false, version name/code equal to pubspec.yaml, and AURELIAN_CALLER_CERTS
#     exactly equal to APPROVED_AURELIAN_RELEASE_CERTS in android/app/build.gradle;
#   * jarsigner verification and the GoodLift upload certificate.
# Exits non-zero on any mismatch. Run from anywhere in PowerShell:
#   powershell -File tool\verify_release_aab.ps1 [-Aab <path>]
param(
    [string] $Aab = 'build/app/outputs/bundle/release/app-release.aab',
    # GoodLift upload certificate (Play upload key, not Google's app-signing key).
    [string] $UploadCertSha256 = 'BA:20:8D:41:BB:76:16:D1:D4:6A:2B:A3:EA:F6:18:85:72:60:98:2C:B7:65:FE:84:5C:5A:38:2C:20:51:A4:49'
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$failures = New-Object System.Collections.Generic.List[string]
function Expect([string] $label, $actual, $expected) {
    if ("$actual" -ceq "$expected") { Write-Output "OK    $label = $actual" }
    else { Write-Output "FAIL  $label = '$actual' (expected '$expected')"; $failures.Add($label) }
}

$aabPath = (Resolve-Path $Aab).Path
$gradle = Get-Content 'android/app/build.gradle' -Raw
$approved = [regex]::Match($gradle, "def APPROVED_AURELIAN_RELEASE_CERTS = '([0-9a-f,]+)'").Groups[1].Value
if (-not $approved) { throw 'APPROVED_AURELIAN_RELEASE_CERTS not found in android/app/build.gradle.' }
$version = ((Get-Content 'pubspec.yaml' | Where-Object { $_ -match '^version:\s*' }) -replace '^version:\s*', '').Trim()
$versionName, $versionCode = $version -split '\+'

$sdk = ([regex]::Match((Get-Content 'android/local.properties' -Raw), '(?m)^sdk\.dir=(.+)$').Groups[1].Value.Trim()) -replace '\\\\', '\' -replace '\\:', ':'
$dexdump = Get-ChildItem (Join-Path $sdk 'build-tools') -Directory | Sort-Object { [version]($_.Name -replace '[^0-9.].*$', '') } |
    ForEach-Object { Join-Path $_.FullName 'dexdump.exe' } | Where-Object { Test-Path $_ } | Select-Object -Last 1
if (-not $dexdump) { throw "dexdump.exe not found under $sdk\build-tools." }

# The app's BuildConfig, read from the DEX inside the bundle.
$work = Join-Path ([IO.Path]::GetTempPath()) ("goodlift-aab-" + [guid]::NewGuid())
New-Item -ItemType Directory $work | Out-Null
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($aabPath)
    try {
        foreach ($e in $zip.Entries | Where-Object { $_.FullName -like 'base/dex/*.dex' }) {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $work $e.Name))
        }
    } finally { $zip.Dispose() }
    $fields = $null
    foreach ($dex in Get-ChildItem $work -Filter *.dex) {
        $lines = & $dexdump -f $dex.FullName 2>$null
        $start = [array]::IndexOf($lines, ($lines | Where-Object { $_ -match "Class descriptor\s*:\s*'Lcom/goodlift/razorsedge/BuildConfig;'" } | Select-Object -First 1))
        if ($start -lt 0) { continue }
        if ($fields) { throw 'More than one com.goodlift.razorsedge.BuildConfig in the bundle.' }
        $fields = @{}
        $name = $null
        for ($i = $start + 1; $i -lt $lines.Count -and $lines[$i] -notmatch 'Class descriptor'; $i++) {
            if ($lines[$i] -match "^\s*name\s*:\s*'(\w+)'") { $name = $matches[1] }
            elseif ($name -and $lines[$i] -match '^\s*value\s*:\s*"?(.*?)"?\s*$') { $fields[$name] = $matches[1]; $name = $null }
        }
    }
    if (-not $fields) { throw 'com.goodlift.razorsedge.BuildConfig not found in the bundle DEX.' }
} finally { Remove-Item -Recurse -Force $work }

Expect 'BuildConfig.APPLICATION_ID' $fields['APPLICATION_ID'] 'com.goodlift.razorsedge'
Expect 'BuildConfig.BUILD_TYPE' $fields['BUILD_TYPE'] 'release'
Expect 'BuildConfig.DEBUG' $fields['DEBUG'] 'false'
Expect 'BuildConfig.VERSION_NAME' $fields['VERSION_NAME'] $versionName
Expect 'BuildConfig.VERSION_CODE' $fields['VERSION_CODE'] $versionCode
Expect 'BuildConfig.AURELIAN_CALLER_CERTS' $fields['AURELIAN_CALLER_CERTS'] $approved

$signer = (& jarsigner -verify $aabPath 2>&1 | Out-String)
Expect 'jarsigner exit code' $LASTEXITCODE 0
Expect 'jarsigner result' ([bool]($signer -match 'jar verified\.')) $true
$cert = (& keytool -printcert -jarfile $aabPath 2>&1 | Out-String)
$sha = [regex]::Matches($cert, 'SHA256:\s*([0-9A-F:]{95})') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
Expect 'upload certificate SHA-256' ($sha -join ',') $UploadCertSha256
Expect 'signed with an Android Debug key' ([bool]($cert -match 'CN=Android Debug')) $false

$hash = (Get-FileHash $aabPath -Algorithm SHA256).Hash.ToLower()
Write-Output "AAB   $aabPath"
Write-Output "      $((Get-Item $aabPath).Length) bytes, SHA-256 $hash"
if ($failures.Count) { Write-Output "RELEASE AAB VERIFICATION FAILED: $($failures -join '; ')"; exit 1 }
Write-Output 'RELEASE AAB VERIFIED'
exit 0
