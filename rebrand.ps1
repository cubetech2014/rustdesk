# CubeRemote 브랜딩 스크립트 (PowerShell 버전)
# RustDesk 포크 소스 루트에서 실행
# 사용법:
#   powershell -ExecutionPolicy Bypass -File rebrand.ps1 agent
#   powershell -ExecutionPolicy Bypass -File rebrand.ps1 viewer

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('agent','viewer')]
    [string]$Flavor = 'agent'
)

$ErrorActionPreference = 'Stop'

# ---- 공통 서버 설정 ----
$RDV_SERVER   = "203.245.29.78"
$API_BASE     = "https://remote.cube-tech.co.kr/api/cuberemote"
$PUB_KEY      = "i3sWZx4sShCLVGZ3mPoZVbzeYfc7VK1pOy2XdrRhkt0="

# ---- flavor별 차이 ----
if ($Flavor -eq 'agent') {
    $NEW_PKG  = "com.cube.cuberemote"
    $NEW_NAME = "CubeRemote"
} else {
    $NEW_PKG  = "com.cube.cuberemote.viewer"
    $NEW_NAME = "CubeRemote 관리자"
}

$OLD_PKG  = "com.carriez.flutter_hbb"
$OLD_NAME = "RustDesk"

Write-Host "=== CubeRemote 브랜딩: flavor=$Flavor ===" -ForegroundColor Cyan

# 1) 패키지명 치환
Write-Host "[1/5] 패키지명 변경: $OLD_PKG -> $NEW_PKG"
$ext = @('*.gradle','*.kt','*.java','*.xml','*.dart','*.rs')
$dirs = @('flutter/android','src','libs')
$files = foreach ($d in $dirs) {
    if (Test-Path $d) {
        Get-ChildItem -Path $d -Recurse -File -Include $ext -ErrorAction SilentlyContinue
    }
}
foreach ($f in $files) {
    $content = Get-Content -Raw -Encoding UTF8 $f.FullName
    if ($content -match [regex]::Escape($OLD_PKG)) {
        $newContent = $content -replace [regex]::Escape($OLD_PKG), $NEW_PKG
        Set-Content -Path $f.FullName -Value $newContent -Encoding UTF8 -NoNewline
    }
}

# Kotlin 디렉토리 이동
$OLD_DIR = "flutter\android\app\src\main\kotlin\com\carriez\flutter_hbb"
if (Test-Path $OLD_DIR) {
    if ($Flavor -eq 'agent') {
        $NEW_DIR = "flutter\android\app\src\main\kotlin\com\cube\cuberemote"
    } else {
        $NEW_DIR = "flutter\android\app\src\main\kotlin\com\cube\cuberemote\viewer"
    }
    $parent = Split-Path $NEW_DIR -Parent
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    git mv $OLD_DIR $NEW_DIR 2>$null
    if ($LASTEXITCODE -ne 0) {
        Move-Item -Path $OLD_DIR -Destination $NEW_DIR -Force
    }
}

# 2) 앱 이름
Write-Host "[2/5] 앱 이름: $OLD_NAME -> $NEW_NAME"
$manifest = "flutter\android\app\src\main\AndroidManifest.xml"
if (Test-Path $manifest) {
    $c = Get-Content -Raw -Encoding UTF8 $manifest
    $c = $c -replace [regex]::Escape("android:label=`"$OLD_NAME`""), "android:label=`"$NEW_NAME`""
    Set-Content -Path $manifest -Value $c -Encoding UTF8 -NoNewline
}

# 3) 서버 주소 하드코딩
Write-Host "[3/5] 서버 주소 하드코딩"
$CONFIG_RS = "libs\hbb_common\src\config.rs"
if (Test-Path $CONFIG_RS) {
    $c = Get-Content -Raw -Encoding UTF8 $CONFIG_RS
    $c = $c -replace 'pub const RENDEZVOUS_SERVERS: .*', "pub const RENDEZVOUS_SERVERS: &[&str] = &[`"$RDV_SERVER`"];"
    $c = $c -replace 'pub const RS_PUB_KEY: &str = ".*";', "pub const RS_PUB_KEY: &str = `"$PUB_KEY`";"
    Set-Content -Path $CONFIG_RS -Value $c -Encoding UTF8 -NoNewline
}

# 4) 아이콘 교체
Write-Host "[4/5] 앱 아이콘 교체"
$ICONS_DIR = "overlay\icons\$Flavor"
if (-not (Test-Path $ICONS_DIR)) {
    $ICONS_DIR = "overlay\icons"
}
if (Test-Path $ICONS_DIR) {
    $iconMap = @{
        "hdpi.png"    = "flutter\android\app\src\main\res\mipmap-hdpi\ic_launcher.png"
        "xhdpi.png"   = "flutter\android\app\src\main\res\mipmap-xhdpi\ic_launcher.png"
        "xxhdpi.png"  = "flutter\android\app\src\main\res\mipmap-xxhdpi\ic_launcher.png"
        "xxxhdpi.png" = "flutter\android\app\src\main\res\mipmap-xxxhdpi\ic_launcher.png"
    }
    foreach ($src in $iconMap.Keys) {
        $srcPath = Join-Path $ICONS_DIR $src
        $dstPath = $iconMap[$src]
        if ((Test-Path $srcPath) -and (Test-Path (Split-Path $dstPath -Parent))) {
            Copy-Item $srcPath $dstPath -Force
        }
    }
}

# 5) CubeRemote Flutter 모듈 복사 + flavor 주입
Write-Host "[5/5] CubeRemote 모듈 오버레이"
if (Test-Path "overlay\flutter") {
    Copy-Item -Recurse -Force "overlay\flutter\*" "flutter\"
}

$cfgDart = "flutter\lib\cuberemote\config.dart"
if (Test-Path $cfgDart) {
    $c = Get-Content -Raw -Encoding UTF8 $cfgDart
    $c = $c -replace 'const API_BASE = .*', "const API_BASE = `"$API_BASE`";"
    $c = $c -replace 'defaultValue: "agent"', "defaultValue: `"$Flavor`""
    Set-Content -Path $cfgDart -Value $c -Encoding UTF8 -NoNewline
}

Write-Host ""
Write-Host "=== 브랜딩 완료 (flavor=$Flavor) ===" -ForegroundColor Green
Write-Host "다음: git status / git add -A / git commit / git tag / git push"
