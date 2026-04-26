#!/bin/bash
# CubeRemote 빌드 시간 패치
# CI에서 submodule init 후 / cargo, flutter build 전에 실행
# 사용법: bash patches/apply.sh

set -e

echo "=== CubeRemote 빌드 패치 ==="

RDV_SERVER="203.245.29.78"
PUB_KEY="i3sWZx4sShCLVGZ3mPoZVbzeYfc7VK1pOy2XdrRhkt0="

# ============================================
# hbb_common 서버 주소 + 공개키 하드코딩
# (libs/hbb_common 은 git submodule 이므로 우리 fork commit 으로는 변경 불가능 → CI에서 패치)
# ============================================
CONFIG_RS="libs/hbb_common/src/config.rs"
if [ ! -f "$CONFIG_RS" ]; then
    echo "[ERROR] $CONFIG_RS not found. submodule이 초기화되지 않은 것 같습니다."
    echo "        actions/checkout에 'submodules: recursive' 옵션이 있는지 확인."
    exit 1
fi

echo "[패치] $CONFIG_RS"

# 패치 전 원본 보관 (확인용)
ORIG_RDV=$(grep '^pub const RENDEZVOUS_SERVERS' "$CONFIG_RS" || echo '')
ORIG_KEY=$(grep '^pub const RS_PUB_KEY' "$CONFIG_RS" || echo '')
echo "  원본 RENDEZVOUS_SERVERS: $ORIG_RDV"
echo "  원본 RS_PUB_KEY:         $ORIG_KEY"

# RENDEZVOUS_SERVERS = &["우리 서버"]
sed -i "s|^pub const RENDEZVOUS_SERVERS:.*|pub const RENDEZVOUS_SERVERS: \\&[\\&str] = \\&[\"$RDV_SERVER\"];|" "$CONFIG_RS"

# RS_PUB_KEY = "우리 공개키"
sed -i "s|^pub const RS_PUB_KEY:.*|pub const RS_PUB_KEY: \\&str = \"$PUB_KEY\";|" "$CONFIG_RS"

# 패치 후 결과
echo "  ----"
NEW_RDV=$(grep '^pub const RENDEZVOUS_SERVERS' "$CONFIG_RS" || echo '')
NEW_KEY=$(grep '^pub const RS_PUB_KEY' "$CONFIG_RS" || echo '')
echo "  패치 RENDEZVOUS_SERVERS: $NEW_RDV"
echo "  패치 RS_PUB_KEY:         $NEW_KEY"

# 검증: 패치가 정확히 적용됐는지 확인. 실패 시 빌드 중단
if ! grep -q "\"$RDV_SERVER\"" "$CONFIG_RS"; then
    echo ""
    echo "[FATAL] 서버 주소 패치 실패. RENDEZVOUS_SERVERS 라인 형식이 예상과 다릅니다."
    exit 1
fi
if ! grep -q "\"$PUB_KEY\"" "$CONFIG_RS"; then
    echo ""
    echo "[FATAL] 공개키 패치 실패. RS_PUB_KEY 라인 형식이 예상과 다릅니다."
    exit 1
fi

echo ""
echo "=== 패치 완료 ==="
