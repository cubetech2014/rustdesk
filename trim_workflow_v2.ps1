# trim_workflow_v2.ps1 - flutter-build.yml 정리
# - .bak 에서 시작 (이미 어느 정도 손상된 yml이라도 안전하게 복원)
# - 정확한 job 이름으로 비활성화 (이전 v1의 오타 수정)
# - Android matrix: aarch64 만 유지
# 사용법: rustdesk-fork-clone 루트에서
#   powershell -ExecutionPolicy Bypass -File trim_workflow_v2.ps1

$ErrorActionPreference = 'Stop'
$file = ".github/workflows/flutter-build.yml"
$bak  = "$file.bak"

if (-not (Test-Path $file)) {
    Write-Error "$file not found. Run from rustdesk-fork-clone root."
    exit 1
}

# 백업이 있으면 거기서 복원, 없으면 새로 만듦
if (Test-Path $bak) {
    Write-Host "백업에서 복원 시작: $bak -> $file" -ForegroundColor Cyan
    Copy-Item $bak $file -Force
} else {
    Write-Host "백업 생성: $file -> $bak" -ForegroundColor Cyan
    Copy-Item $file $bak -Force
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$content = [System.IO.File]::ReadAllText($file, [System.Text.UTF8Encoding]::new($false))
$lines   = $content -split "`r?`n"
$newLines = New-Object System.Collections.Generic.List[string]

# 비활성화할 job 이름 (실제 워크플로우 기준 — 정확)
$disable_jobs = @(
    'build-RustDeskTempTopMostWindow:'
    'build-for-windows-flutter:'
    'build-for-windows-sciter:'
    'build-rustdesk-ios:'
    'build-for-macOS:'
    'publish_unsigned:'
    'build-rustdesk-android-universal:'
    'build-rustdesk-linux:'
    'build-rustdesk-linux-sciter:'
    'build-appimage:'
    'build-flatpak:'
    'build-rustdesk-web:'
)

$skipUntilDedent = $false
$jobIndent = 0

foreach ($line in $lines) {
    if ($skipUntilDedent) {
        $deeperIndentRegex = '^( {' + ($jobIndent + 1) + ',})'
        if ($line.Trim() -eq '' -or ($line -match $deeperIndentRegex)) {
            $newLines.Add('# ' + $line)
            continue
        } else {
            $skipUntilDedent = $false
        }
    }

    $matched = $false
    foreach ($jobName in $disable_jobs) {
        $jobLineRegex = '^(\s+)' + [regex]::Escape($jobName) + '\s*$'
        if ($line -match $jobLineRegex) {
            $jobIndent = $Matches[1].Length
            $newLines.Add('# DISABLED: ' + $line)
            $skipUntilDedent = $true
            $matched = $true
            break
        }
    }
    if (-not $matched) {
        $newLines.Add($line)
    }
}

$newContent = ($newLines -join "`n")

# Android matrix: armv7, x86_64 항목 제거 (aarch64 만 유지)
# 매트릭스 항목 패턴: "- {\n  arch: armv7,\n  target: ...\n  ...\n},"
$newContent = [regex]::Replace($newContent,
    '(?ms)^\s*-\s*\{\s*\r?\n\s*arch:\s*armv7,[^}]*?\}\s*,?\s*\r?\n', '')
$newContent = [regex]::Replace($newContent,
    '(?ms)^\s*-\s*\{\s*\r?\n\s*arch:\s*x86_64,\s*\r?\n\s*target:\s*x86_64-linux-android,[^}]*?\}\s*,?\s*\r?\n', '')

[System.IO.File]::WriteAllText($file, $newContent, $utf8NoBom)

# 'Apply CubeRemote branding patches' step 재주입 필요 → inject_patch_step.ps1 호출 권장
Write-Host ""
Write-Host "=== 워크플로우 트림 완료 ===" -ForegroundColor Green
Write-Host "비활성화된 job:"
foreach ($j in $disable_jobs) { Write-Host "  - $j" }
Write-Host ""
Write-Host "Android matrix: aarch64 만 유지" -ForegroundColor Green
Write-Host ""
Write-Host "다음 단계:" -ForegroundColor Yellow
Write-Host "  1. inject_patch_step.ps1  (Apply CubeRemote branding patches step 재주입)"
Write-Host "  2. git add -A && git commit -m '...' && git push"
