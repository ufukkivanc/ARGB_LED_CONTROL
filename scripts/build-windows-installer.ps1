<#
.SYNOPSIS
  ARGB Controller için Windows kurulum paketini (tek EXE) tekrarlanabilir biçimde üretir.

.DESCRIPTION
  1. Ön kontroller (Flutter, Inno Setup, VC++ çalışma zamanı DLL'leri)
  2. flutter pub get, (isteğe bağlı) flutter analyze + flutter test
  3. flutter build windows --release   (klasör yolu ASCII değilse otomatik 'subst' sürücü harfi kullanılır)
  4. dist\stage: Release çıktısı + VC++ DLL'leri (msvcp140, vcruntime140, vcruntime140_1)
  5. Inno Setup ile dist\ARGBController-Setup-<sürüm>.exe ve .sha256

  Sürüm numarası argb_controller_app\pubspec.yaml içindeki 'version: x.y.z+n' değerinden okunur.

.PARAMETER SkipTests     flutter test adımını atlar.
.PARAMETER SkipAnalyze   flutter analyze adımını atlar.
.PARAMETER Clean         Derlemeden önce flutter clean çalıştırır.
.PARAMETER IsccPath      ISCC.exe yolunu elle verir (varsayılan: otomatik arama / ISCC_PATH ortam değişkeni).
.PARAMETER CrtDir        VC++ DLL klasörünü elle verir (örn. ...\VC\Redist\MSVC\14.xx\x64\Microsoft.VC145.CRT).
.PARAMETER SignToolPath  (İsteğe bağlı) signtool.exe yolu.
.PARAMETER SignCertThumbprint  (İsteğe bağlı) Kod imzalama sertifikasının SHA1 parmak izi. Verilirse exe ve kurulum dosyası imzalanır.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\build-windows-installer.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\build-windows-installer.ps1 -SkipTests -SkipAnalyze
#>
[CmdletBinding()]
param(
  [switch]$SkipTests,
  [switch]$SkipAnalyze,
  [switch]$Clean,
  [string]$IsccPath,
  [string]$CrtDir,
  [string]$SignToolPath,
  [string]$SignCertThumbprint
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Step([string]$msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail([string]$msg) { Write-Host "HATA: $msg" -ForegroundColor Red; exit 1 }
function Run([string]$what, [scriptblock]$cmd) {
  & $cmd
  if ($LASTEXITCODE -ne 0) { Fail "$what başarısız oldu (çıkış kodu $LASTEXITCODE)." }
}

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$AppDir = Join-Path $Root 'argb_controller_app'
$Dist = Join-Path $Root 'dist'
$Stage = Join-Path $Dist 'stage'
$Iss = Join-Path $Root 'installer\ARGBController.iss'

# ── Sürüm ───────────────────────────────────────────────────────────────────
$pubspec = Get-Content (Join-Path $AppDir 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?') { Fail "pubspec.yaml içinde 'version: x.y.z+n' bulunamadı." }
$Major = [int]$Matches[1]; $Minor = [int]$Matches[2]; $Patch = [int]$Matches[3]
$Build = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
$AppVersion = "$Major.$Minor.$Patch"
$AppVersionInfo = "$Major.$Minor.$Patch.$Build"
Write-Host "Sürüm: $AppVersion (dosya sürümü $AppVersionInfo)"

# ── Ön kontroller ────────────────────────────────────────────────────────────
Step 'Ön kontroller'
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { Fail 'flutter bulunamadı. Flutter SDK kurulu ve PATH içinde olmalı.' }

function Find-Iscc {
  if ($IsccPath -and (Test-Path $IsccPath)) { return $IsccPath }
  if ($env:ISCC_PATH -and (Test-Path $env:ISCC_PATH)) { return $env:ISCC_PATH }
  $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($p in @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")) {
    if (Test-Path $p) { return $p }
  }
  return $null
}
$Iscc = Find-Iscc
if (-not $Iscc) { Fail "Inno Setup 6 bulunamadı. Kurmak için: winget install JRSoftware.InnoSetup  (veya -IsccPath / ISCC_PATH verin)." }
Write-Host "Inno Setup : $Iscc"

function Find-CrtDir {
  if ($CrtDir -and (Test-Path (Join-Path $CrtDir 'vcruntime140.dll'))) { return $CrtDir }
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  $roots = @()
  if (Test-Path $vswhere) {
    $p = & $vswhere -latest -products * -property installationPath 2>$null
    if ($p) { $roots += $p }
  }
  $roots += Get-ChildItem "$env:ProgramFiles\Microsoft Visual Studio", "${env:ProgramFiles(x86)}\Microsoft Visual Studio" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue } | ForEach-Object { $_.FullName }
  foreach ($r in $roots) {
    $redist = Join-Path $r 'VC\Redist\MSVC'
    if (-not (Test-Path $redist)) { continue }
    $cand = Get-ChildItem $redist -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
      Sort-Object { [version]$_.Name } -Descending
    foreach ($c in $cand) {
      $crt = Get-ChildItem (Join-Path $c.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($crt -and (Test-Path (Join-Path $crt.FullName 'vcruntime140.dll'))) { return $crt.FullName }
    }
  }
  return $null
}
$Crt = Find-CrtDir
if (-not $Crt) { Fail "VC++ çalışma zamanı DLL klasörü bulunamadı. Visual Studio 'Desktop development with C++' kurun veya -CrtDir verin." }
Write-Host "VC++ DLL   : $Crt"
$CrtDlls = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
foreach ($d in $CrtDlls) { if (-not (Test-Path (Join-Path $Crt $d))) { Fail "$d bulunamadı: $Crt" } }

# ── ASCII olmayan klasör yolu: 'Ç' vb. karakterler Flutter/MSBuild derlemesini bozar → subst ──────────────────────
$Subst = $null
$BuildAppDir = $AppDir
if ($Root -match '[^\x00-\x7F]') {
  $used = (Get-PSDrive -PSProvider FileSystem).Name
  $letter = 'Z', 'Y', 'X', 'W', 'V', 'U' | Where-Object { $used -notcontains $_ } | Select-Object -First 1
  if (-not $letter) { Fail "Proje yolu ASCII olmayan karakter içeriyor ve boş sürücü harfi yok. Projeyi ASCII bir klasöre taşıyın." }
  Write-Host "Proje yolu ASCII olmayan karakter içeriyor; geçici sürücü ${letter}: kullanılacak."
  subst "${letter}:" $Root
  $Subst = "${letter}:"
  $BuildAppDir = "${letter}:\argb_controller_app"
}

try {
  Push-Location $BuildAppDir

  # ── Hazırlık, analiz, test ──────────────────────────────────────────────────
  if ($Clean) { Step 'flutter clean'; Run 'flutter clean' { flutter clean } }
  Step 'flutter pub get'
  Run 'flutter pub get' { flutter pub get }

  if (-not $SkipAnalyze) {
    Step 'flutter analyze'
    Run 'flutter analyze' { flutter analyze --no-fatal-infos --no-fatal-warnings }
  }
  if (-not $SkipTests) {
    Step 'flutter test'
    Run 'flutter test' { flutter test }
  }

  # ── Release derleme ─────────────────────────────────────────────────────────
  Step 'flutter build windows --release'
  Run 'flutter build windows --release' { flutter build windows --release }
  $Release = Join-Path $BuildAppDir 'build\windows\x64\runner\Release'
  $Exe = Join-Path $Release 'ARGBController.exe'
  if (-not (Test-Path $Exe)) { Fail "Release çıktısı bulunamadı: $Exe" }
  if (-not (Test-Path (Join-Path $Release 'data\flutter_assets'))) { Fail 'Release çıktısında data\flutter_assets yok.' }
  $vi = (Get-Item $Exe).VersionInfo
  Write-Host "Exe        : $($vi.ProductName) $($vi.ProductVersion)  ($($vi.FileDescription))"
  if ($vi.ProductName -ne 'ARGB Controller') { Fail "Exe ürün adı beklenmiyor: '$($vi.ProductName)'" }
}
finally {
  Pop-Location
  if ($Subst) { subst $Subst /D | Out-Null }
}

# ── Hazırlama (stage) ────────────────────────────────────────────────────────
Step 'Kurulum paketi içeriği hazırlanıyor'
$ReleaseReal = Join-Path $Root 'argb_controller_app\build\windows\x64\runner\Release'
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage -Force | Out-Null
Copy-Item (Join-Path $ReleaseReal '*') $Stage -Recurse -Force
foreach ($d in $CrtDlls) { Copy-Item (Join-Path $Crt $d) $Stage -Force }
Get-ChildItem $Stage -Filter *.pdb -Recurse | Remove-Item -Force
$files = Get-ChildItem $Stage -Recurse -File
Write-Host ("{0} dosya, {1:N1} MB" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB))

# ── İsteğe bağlı kod imzalama (exe) ─────────────────────────────────────────────
function Sign-File([string]$path) {
  if (-not $SignCertThumbprint) { return }
  $st = $SignToolPath
  if (-not $st) { $c = Get-Command signtool.exe -ErrorAction SilentlyContinue; if ($c) { $st = $c.Source } }
  if (-not $st) { Fail 'signtool.exe bulunamadı (-SignToolPath verin).' }
  Run "İmzalama ($path)" { & $st sign /sha1 $SignCertThumbprint /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /d 'ARGB Controller' $path }
}
Sign-File (Join-Path $Stage 'ARGBController.exe')

# ── Inno Setup ──────────────────────────────────────────────────────────────
Step 'Inno Setup derleniyor'
New-Item -ItemType Directory -Path $Dist -Force | Out-Null
Run 'Inno Setup' { & $Iscc "/DAppVersion=$AppVersion" "/DAppVersionInfo=$AppVersionInfo" "/DSourceDir=$Stage" "/DOutputDir=$Dist" "/Qp" $Iss }
$Setup = Join-Path $Dist "ARGBController-Setup-$AppVersion.exe"
if (-not (Test-Path $Setup)) { Fail "Kurulum dosyası üretilemedi: $Setup" }
Sign-File $Setup

$hash = (Get-FileHash $Setup -Algorithm SHA256).Hash.ToLower()
"$hash  $(Split-Path $Setup -Leaf)" | Set-Content -Path "$Setup.sha256" -Encoding ASCII

Step 'TAMAM'
Write-Host ("Kurulum dosyası : {0}  ({1:N1} MB)" -f $Setup, ((Get-Item $Setup).Length / 1MB)) -ForegroundColor Green
Write-Host "SHA-256         : $hash"
if (-not $SignCertThumbprint) {
  Write-Host 'UYARI: Dosya kod imzalı DEĞİL; Windows SmartScreen "Bilinmeyen yayıncı" uyarısı gösterebilir (docs/WINDOWS_DISTRIBUTION.md).' -ForegroundColor Yellow
}
