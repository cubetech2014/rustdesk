# BOM 일괄 제거 스크립트 - 텍스트 파일에서 UTF-8 BOM 제거
# rustdesk-fork-clone 루트에서 실행

$ErrorActionPreference = 'Continue'
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$bom = [byte[]](0xEF, 0xBB, 0xBF)

$ext = @('*.gradle','*.kt','*.java','*.xml','*.dart','*.rs','*.yml','*.yaml','*.md','*.toml','*.json','*.properties')
$dirs = @('flutter','src','libs','.github')

$count = 0
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) { continue }
    Get-ChildItem -Path $d -Recurse -File -Include $ext -ErrorAction SilentlyContinue | ForEach-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $newBytes = New-Object byte[] ($bytes.Length - 3)
            [Array]::Copy($bytes, 3, $newBytes, 0, $newBytes.Length)
            [System.IO.File]::WriteAllBytes($_.FullName, $newBytes)
            $count++
            Write-Host "BOM removed: $($_.FullName)"
        }
    }
}

Write-Host ""
Write-Host "=== $count 개 파일에서 BOM 제거 완료 ===" -ForegroundColor Green
