#!/bin/bash
# CubeRemote 빌드 시간 패치
# CI에서 submodule init 후 / cargo, flutter build 전에 실행

set -e

echo "=== CubeRemote 빌드 패치 ==="

RDV_SERVER="203.245.29.78"
PUB_KEY="i3sWZx4sShCLVGZ3mPoZVbzeYfc7VK1pOy2XdrRhkt0="

CONFIG_RS="libs/hbb_common/src/config.rs"
if [ ! -f "$CONFIG_RS" ]; then
    echo "[ERROR] $CONFIG_RS not found. submodule이 초기화되지 않은 것 같습니다."
    exit 1
fi

# 이미 우리 서버 + 공개키면 skip
if grep -q "\"$RDV_SERVER\"" "$CONFIG_RS" && grep -q "\"$PUB_KEY\"" "$CONFIG_RS"; then
    echo "[OK] $CONFIG_RS 이미 패치되어 있음 (skip)"
    grep '^pub const RENDEZVOUS_SERVERS' "$CONFIG_RS"
    grep '^pub const RS_PUB_KEY' "$CONFIG_RS"
    echo "=== 패치 완료 ==="
    exit 0
fi

echo "[패치] $CONFIG_RS"

# 디렉토리/파일 쓰기 권한 강제 부여 (submodule 권한 이슈 우회)
chmod -R u+w libs/hbb_common 2>/dev/null || true

# sed -i 권한 문제 우회: 임시파일 거쳐서 cp
TMP=$(mktemp)
sed -e "s|^pub const RENDEZVOUS_SERVERS:.*|pub const RENDEZVOUS_SERVERS: \\&[\\&str] = \\&[\"$RDV_SERVER\"];|" \
    -e "s|^pub const RS_PUB_KEY:.*|pub const RS_PUB_KEY: \\&str = \"$PUB_KEY\";|" \
    "$CONFIG_RS" > "$TMP"
cp "$TMP" "$CONFIG_RS"
rm -f "$TMP"

echo "  결과:"
grep '^pub const RENDEZVOUS_SERVERS' "$CONFIG_RS" || echo "  (RENDEZVOUS_SERVERS 라인을 찾을 수 없음)"
grep '^pub const RS_PUB_KEY' "$CONFIG_RS" || echo "  (RS_PUB_KEY 라인을 찾을 수 없음)"

# 검증: 패치가 정확히 적용됐는지
if ! grep -q "\"$RDV_SERVER\"" "$CONFIG_RS"; then
    echo "[FATAL] 서버 주소 패치 실패"
    exit 1
fi
if ! grep -q "\"$PUB_KEY\"" "$CONFIG_RS"; then
    echo "[FATAL] 공개키 패치 실패"
    exit 1
fi

echo "=== 패치 완료 ==="
