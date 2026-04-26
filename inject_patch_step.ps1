# flutter-build.yml의 빌드 잡들에 CubeRemote 패치 적용 step 삽입
# Checkout source code 직후에 'Apply CubeRemote branding' step 추가
# 사용법: rustdesk-fork-clone 루트에서
#   powershell -ExecutionPolicy Bypass -File inject_patch_step.ps1

$ErrorActionPreference = 'Stop'
$file = ".github/workflows/flutter-build.yml"

if (-not (Test-Path $file)) {
    Write-Error "$file not found"
    exit 1
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$content = [System.IO.File]::ReadAllText($file, [System.Text.UTF8Encoding]::new($false))

# 삽입할 step (들여쓰기 6스페이스 = job step 레벨)
$injectStep = @"

      - name: Apply CubeRemote branding patches
        shell: bash
        run: bash patches/apply.sh
"@

# "- name: Checkout source code" 다음의 "with:\n submodules: recursive" 블록 끝부분 뒤에 삽입
# 패턴: "submodules: recursive" 다음 줄 → 이미 우리가 추가한 곳 찾기
# 안전하게: "submodules: recursive" 가 나오는 모든 위치 다음에 패치 step 삽입

$pattern = '(?m)^(\s+submodules:\s*recursive\s*$)'

# 이미 패치 step이 들어가 있으면 중복 방지
if ($content -match 'Apply CubeRemote branding patches') {
    Write-Host "이미 패치 step이 삽입되어 있습니다." -ForegroundColor Yellow
    exit 0
}

$newContent = [regex]::Replace($content, $pattern, "`$1$injectStep")

[System.IO.File]::WriteAllText($file, $newContent, $utf8NoBom)

# 삽입 횟수 확인
$count = ([regex]::Matches($newContent, 'Apply CubeRemote branding patches')).Count
Write-Host "=== 완료: $count 곳에 패치 step 삽입됨 ===" -ForegroundColor Green
