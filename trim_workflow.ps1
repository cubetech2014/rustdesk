# flutter-build.yml 에서 우리에게 필요 없는 job 비활성화
# 사용법: rustdesk-fork-clone 루트에서 실행
#   powershell -ExecutionPolicy Bypass -File trim_workflow.ps1

$ErrorActionPreference = 'Stop'
$file = ".github/workflows/flutter-build.yml"

if (-not (Test-Path $file)) {
    Write-Error "$file not found. Run from RustDesk fork clone root."
    exit 1
}

Write-Host "백업: $file -> $file.bak"
Copy-Item $file "$file.bak" -Force

# 비활성화할 job 이름
$disable_jobs = @(
    'build-for-macOS:'
    'build-for-windows:'           # sciter Windows (flutter 아님)
    'build-rustdesk-linux-sciter:'
    'build-for-linux-flutter:'
    'build-rustdesk-android-universal:'
    'build-flatpak:'
    'build-appimage:'
    'build-rustdesk-web:'
    'build-rustdesk-ios:'
)

$content = Get-Content -Raw -Encoding UTF8 $file
$lines = $content -split "`r?`n"
$newLines = New-Object System.Collections.Generic.List[string]

$skipUntilDedent = $false
$jobIndent = 0

foreach ($line in $lines) {
    if ($skipUntilDedent) {
        # 빈 줄이거나 jobIndent 보다 깊은 들여쓰기면 계속 스킵 (주석화)
        if ($line.Trim() -eq '' -or ($line -match "^( {$($jobIndent + 1),})") -or ($line -match "^( {$jobIndent}\S)" -eq $false)) {
            $newLines.Add('# ' + $line)
            continue
        } else {
            $skipUntilDedent = $false
        }
    }

    # job 이름 패턴 매칭: "  build-foo:"
    $matched = $false
    foreach ($jobName in $disable_jobs) {
        if ($line -match "^(\s+)$([regex]::Escape($jobName))\s*$") {
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

# Android matrix에서 armv7, x86_64 제거 (aarch64만 남김)
$newContent = ($newLines -join "`n")

# armv7 / x86_64 / i686 entry 제거 (build-rustdesk-android의 matrix 안에서)
$newContent = [regex]::Replace($newContent,
    '(?m)^\s*-\s*\{\s*\r?\n\s*arch:\s*armv7,[\s\S]*?\}\s*,?\s*\r?\n', '', 'Multiline')
$newContent = [regex]::Replace($newContent,
    '(?m)^\s*-\s*\{\s*\r?\n\s*arch:\s*x86_64,\s*\r?\n\s*target:\s*x86_64-linux-android,[\s\S]*?\}\s*,?\s*\r?\n', '', 'Multiline')

Set-Content -Path $file -Value $newContent -Encoding UTF8 -NoNewline

Write-Host ""
Write-Host "=== 완료 ===" -ForegroundColor Green
Write-Host "비활성화된 job들:"
foreach ($j in $disable_jobs) { Write-Host "  - $j" }
Write-Host ""
Write-Host "Android matrix: aarch64 만 유지"
Write-Host ""
Write-Host "변경 확인: git diff $file"
