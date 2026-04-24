#!/bin/bash
# CubeRemote 브랜딩 스크립트 - RustDesk 포크 소스 루트에서 실행
# 사용법:
#   bash rebrand.sh agent     # POS용 (기본)
#   bash rebrand.sh viewer    # 관리자용

set -e

FLAVOR="${1:-agent}"

# ---- 공통 서버 설정 ----
RDV_SERVER="203.245.29.78"
RELAY_SERVER="203.245.29.78"
API_BASE="https://remote.cube-tech.co.kr/api/cuberemote"
PUB_KEY="i3sWZx4sShCLVGZ3mPoZVbzeYfc7VK1pOy2XdrRhkt0="

# ---- flavor별 차이 ----
case "$FLAVOR" in
    agent)
        NEW_PKG="com.cube.cuberemote"
        NEW_NAME="CubeRemote"
        ;;
    viewer)
        NEW_PKG="com.cube.cuberemote.viewer"
        NEW_NAME="CubeRemote 관리자"
        ;;
    *)
        echo "Unknown flavor: $FLAVOR (use: agent|viewer)"
        exit 1
        ;;
esac

OLD_PKG="com.carriez.flutter_hbb"
OLD_NAME="RustDesk"

echo "=== CubeRemote 브랜딩: flavor=$FLAVOR ==="

# 1) 패키지명 치환
echo "[1/5] 패키지명 변경: $OLD_PKG -> $NEW_PKG"
grep -rl "$OLD_PKG" flutter/android src libs --include='*.gradle' --include='*.kt' --include='*.java' --include='*.xml' --include='*.dart' --include='*.rs' 2>/dev/null | xargs sed -i "s|$OLD_PKG|$NEW_PKG|g" || true

# Kotlin 디렉토리 이동 (agent 패키지 기준으로 먼저 맞춘 뒤, viewer는 com/cube/cuberemote/viewer 로 위치)
OLD_DIR="flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb"
if [ -d "$OLD_DIR" ]; then
    if [ "$FLAVOR" = "agent" ]; then
        NEW_DIR="flutter/android/app/src/main/kotlin/com/cube/cuberemote"
    else
        NEW_DIR="flutter/android/app/src/main/kotlin/com/cube/cuberemote/viewer"
    fi
    mkdir -p "$(dirname $NEW_DIR)"
    git mv "$OLD_DIR" "$NEW_DIR" 2>/dev/null || mv "$OLD_DIR" "$NEW_DIR"
fi

# 2) 앱 이름
echo "[2/5] 앱 이름: $OLD_NAME -> $NEW_NAME"
sed -i "s|android:label=\"$OLD_NAME\"|android:label=\"$NEW_NAME\"|g" flutter/android/app/src/main/AndroidManifest.xml 2>/dev/null || true

# 3) 서버 주소 하드코딩
echo "[3/5] 서버 주소 하드코딩"
CONFIG_RS="libs/hbb_common/src/config.rs"
if [ -f "$CONFIG_RS" ]; then
    sed -i "s|pub const RENDEZVOUS_SERVERS: .*|pub const RENDEZVOUS_SERVERS: \\&[\\&str] = \\&[\"$RDV_SERVER\"];|g" "$CONFIG_RS"
    sed -i "s|pub const RS_PUB_KEY: \\&str = \".*\";|pub const RS_PUB_KEY: \\&str = \"$PUB_KEY\";|g" "$CONFIG_RS"
fi

# 4) 아이콘 교체 (agent/viewer 각자 아이콘)
echo "[4/5] 앱 아이콘 교체"
ICONS_DIR="overlay/icons/$FLAVOR"
if [ ! -d "$ICONS_DIR" ]; then
    ICONS_DIR="overlay/icons"  # fallback: 공용
fi
if [ -d "$ICONS_DIR" ]; then
    cp -f $ICONS_DIR/hdpi.png    flutter/android/app/src/main/res/mipmap-hdpi/ic_launcher.png
    cp -f $ICONS_DIR/xhdpi.png   flutter/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png
    cp -f $ICONS_DIR/xxhdpi.png  flutter/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png
    cp -f $ICONS_DIR/xxxhdpi.png flutter/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png
fi

# 5) CubeRemote Flutter 모듈 복사 + flavor 주입
echo "[5/5] CubeRemote 모듈 오버레이"
if [ -d "overlay/flutter" ]; then
    cp -r overlay/flutter/* flutter/
fi

if [ -f "flutter/lib/cuberemote/config.dart" ]; then
    sed -i "s|const API_BASE = .*|const API_BASE = \"$API_BASE\";|g" flutter/lib/cuberemote/config.dart
    sed -i "s|defaultValue: \"agent\"|defaultValue: \"$FLAVOR\"|g" flutter/lib/cuberemote/config.dart
fi

echo ""
echo "=== 브랜딩 완료 (flavor=$FLAVOR) ==="
echo "다음 빌드 명령:"
echo "  flutter build apk --release --dart-define=CUBE_FLAVOR=$FLAVOR"
