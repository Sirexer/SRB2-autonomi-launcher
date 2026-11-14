# Local Windows build, the same steps as the windows job in
# .github/workflows/build.yml. Run from the repository root in PowerShell:
#
#   powershell -ExecutionPolicy Bypass -File packaging\build_windows.ps1
#
# Needs: Flutter (the version in FLUTTER_VERSION of build.yml) and Visual
# Studio 2022 (or Build Tools) with "Desktop development with C++".
# Optional: Python (GeoIP database for the Servers tab), MSYS2 in C:\msys64
# (libopenmpt/libgme for the music player).
# Result: SRB2-Autonomi-Launcher-windows-x64.zip in the repository root.
param([string]$Msys = 'C:\msys64')

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

function Check([string]$what) {
  if ($LASTEXITCODE -ne 0) { throw "$what failed (exit code $LASTEXITCODE)" }
}

$want = (Select-String -Path .github\workflows\build.yml -Pattern "FLUTTER_VERSION: '(.+)'").Matches[0].Groups[1].Value
$have = ((flutter --version --machine | Out-String) | ConvertFrom-Json).frameworkVersion
if ($have -ne $want) {
  Write-Warning "Flutter $have, the builds use $want (see FLUTTER_VERSION in build.yml)."
}

flutter pub get; Check 'flutter pub get'

# Host countries on the Servers tab (DB-IP Lite). Not fatal.
$py = Get-Command py -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
if ($py) {
  & $py.Source tools/build_geoip.py assets/geoip/country.bin
  if ($LASTEXITCODE -ne 0) { Write-Warning 'GeoIP database not built' }
} else {
  Write-Warning 'Python not found: no GeoIP database (country flags on the Servers tab)'
}

$date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
$commit = (git rev-parse --short=7 HEAD).Trim()
# A build folder made for an executable with another name keeps that target
# in its Visual Studio solution, and CMake stops with "No target ...": such a
# folder is started over.
$stale = Get-ChildItem build\windows\x64\runner\*.vcxproj -ErrorAction SilentlyContinue |
  Where-Object { $_.BaseName -ne 'srb2al' }
if ($stale) {
  Write-Host "Removing build\windows (made for $($stale[0].BaseName).exe)"
  Remove-Item -Recurse -Force build\windows
}

flutter build windows --release "--dart-define=BUILD_DATE=$date" "--dart-define=BUILD_COMMIT=$commit" "--dart-define=BUILD_FLUTTER=$have"
Check 'flutter build windows'

$release = 'build\windows\x64\runner\Release'

# MSVC runtime next to the .exe (a clean Windows has no MSVCP140.dll).
foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
  Copy-Item "$env:WINDIR\System32\$dll" -Destination $release
}

# Music libraries from MSYS2 (optional: the launcher also looks in the game folder).
if (Test-Path "$Msys\usr\bin\bash.exe") {
  $env:MSYSTEM = 'MINGW64'
  $env:CHERE_INVOKING = '1'
  # A script file, not "bash -lc <text>": Windows PowerShell 5.1 breaks the
  # quotes of a multi-line argument.
  & "$Msys\usr\bin\bash.exe" -l packaging/bundle_music_windows.sh
  if ($LASTEXITCODE -ne 0) { Write-Warning 'Music libraries not bundled' }
} else {
  Write-Warning "MSYS2 not found in ${Msys}: no libopenmpt/libgme in the build"
}

# antd: from its GitHub release, else the official GitLab mirror (each
# checked against SHA256SUMS), else the copy the launcher already put in
# your data folder. Without it the build goes on.
$ver = (Select-String -Path lib\services\antd_daemon.dart -Pattern "_version = '(v[^']+)'").Matches[0].Groups[1].Value
$asset = 'antd-windows-amd64.exe'
$antdDir = Join-Path $release 'antd'
$gitlab = "https://gitlab.com/api/v4/projects/88885118/packages/generic/ant-sdk/$ver"
# Release files, license files (on GitLab the licenses are release files too).
$sources = @(
  @("https://github.com/WithAutonomi/ant-sdk/releases/download/$ver", "https://raw.githubusercontent.com/WithAutonomi/ant-sdk/$ver"),
  @($gitlab, $gitlab)
)
New-Item -ItemType Directory -Force -Path $antdDir | Out-Null
$ProgressPreference = 'SilentlyContinue'
# Windows PowerShell 5.1 may still offer TLS 1.0 only; GitHub needs 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$bundled = $false
$errors = @()
foreach ($src in $sources) {
  $base, $raw = $src
  try {
    $tmp = Join-Path $env:TEMP "antd-$ver"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    Invoke-WebRequest "$base/$asset" -OutFile "$tmp\$asset" -UseBasicParsing
    Invoke-WebRequest "$base/SHA256SUMS" -OutFile "$tmp\SHA256SUMS" -UseBasicParsing
    $expected = (Get-Content "$tmp\SHA256SUMS" | Where-Object { $_ -match [regex]::Escape($asset) } | Select-Object -First 1).Split(' ')[0]
    $actual = (Get-FileHash "$tmp\$asset" -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { throw "SHA256 mismatch for $asset" }
    Invoke-WebRequest "$raw/LICENSE-MIT" -OutFile "$tmp\LICENSE-MIT" -UseBasicParsing
    Invoke-WebRequest "$raw/LICENSE-APACHE" -OutFile "$tmp\LICENSE-APACHE" -UseBasicParsing
    Copy-Item "$tmp\$asset" "$antdDir\antd.exe"
    Copy-Item "$tmp\LICENSE-MIT", "$tmp\LICENSE-APACHE" $antdDir
    $bundled = $true
    Write-Host "Bundled antd $ver from $(([Uri]$base).Host)"
    break
  } catch {
    $errors += "$(([Uri]$base).Host): $($_.Exception.Message)"
  }
}
if (-not $bundled) {
  # The launcher's data folder.
  $local = Join-Path $env:APPDATA "SRB2 Autonomi Launcher\antd\$ver\antd.exe"
  if (Test-Path $local) {
    Copy-Item $local "$antdDir\antd.exe"
    $bundled = $true
    Write-Warning "antd $ver not downloaded ($($errors -join '; ')); bundled the copy from $local (without the ant-sdk license files)"
  } else {
    Write-Warning "antd $ver not downloaded ($($errors -join '; ')) and not found in $local`: the build has no bundled antd"
  }
}
if ($bundled) {
  Set-Content -Path "$antdDir\VERSION" -Value $ver -Encoding ascii
} else {
  Remove-Item -Recurse -Force $antdDir
}

# The repository the launcher offers to connect on the first start.
Copy-Item packaging\pointer.txt "$release\pointer.txt"
# Attribution of the data in the launcher (DB-IP, flags).
Copy-Item packaging\NOTICE.txt "$release\NOTICE.txt"

$zip = 'SRB2-Autonomi-Launcher-windows-x64.zip'
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path "$release\*" -DestinationPath $zip
Write-Host "Done: $((Resolve-Path $zip).Path)"
