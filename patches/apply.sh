#!/bin/bash
# CubeRemote 통합 빌드 패치
# CI에서 submodule init 후 / cargo, flutter build 전에 실행
# Idempotent: 이미 패치된 항목은 자동 스킵

set -e

echo "=== CubeRemote 통합 빌드 패치 시작 ==="

# === 설정 ===
RDV_SERVER="203.245.29.78"
PUB_KEY="i3sWZx4sShCLVGZ3mPoZVbzeYfc7VK1pOy2XdrRhkt0="
APP_NAME_NEW="CubeRemote"

# === 권한 강제 (submodule 권한 이슈 우회) ===
chmod -R u+w libs flutter src res Cargo.toml 2>/dev/null || true

PATCHED=0
SKIPPED=0

# ────────────────────────────────────────────────────────────
# [1/9] libs/hbb_common/src/config.rs (submodule)
#   - APP_NAME 상수 → CubeRemote
#   - RENDEZVOUS_SERVERS → 우리 서버
#   - RS_PUB_KEY → 우리 공개키
# ────────────────────────────────────────────────────────────
CONFIG_RS="libs/hbb_common/src/config.rs"
if [ -f "$CONFIG_RS" ]; then
    if grep -q "\"$RDV_SERVER\"" "$CONFIG_RS" \
       && grep -q "\"$PUB_KEY\"" "$CONFIG_RS" \
       && grep -q "RwLock::new(\"$APP_NAME_NEW\".to_owned())" "$CONFIG_RS"; then
        echo "[1/9] $CONFIG_RS  (skip — 이미 패치됨)"
        SKIPPED=$((SKIPPED+1))
    else
        echo "[1/9] $CONFIG_RS  패치"
        TMP=$(mktemp)
        sed -e "s|RwLock::new(\"RustDesk\".to_owned())|RwLock::new(\"$APP_NAME_NEW\".to_owned())|" \
            -e "s|^pub const RENDEZVOUS_SERVERS:.*|pub const RENDEZVOUS_SERVERS: \\&[\\&str] = \\&[\"$RDV_SERVER\"];|" \
            -e "s|^pub const RS_PUB_KEY:.*|pub const RS_PUB_KEY: \\&str = \"$PUB_KEY\";|" \
            "$CONFIG_RS" > "$TMP"
        cp "$TMP" "$CONFIG_RS"
        rm -f "$TMP"
        PATCHED=$((PATCHED+1))
    fi
    grep -E '^pub const (RENDEZVOUS_SERVERS|RS_PUB_KEY)|RwLock::new\(".*"\.to_owned' "$CONFIG_RS" | sed 's/^/    /'
else
    echo "[1/9] $CONFIG_RS  없음 (submodule 미초기화 가능성 — CI에서는 자동 init)"
fi

# ────────────────────────────────────────────────────────────
# [2/9] flutter/android/.../strings.xml — Android 런처 라벨
# ────────────────────────────────────────────────────────────
STRINGS_XML="flutter/android/app/src/main/res/values/strings.xml"
if [ -f "$STRINGS_XML" ]; then
    if grep -q "name=\"app_name\">$APP_NAME_NEW<" "$STRINGS_XML"; then
        echo "[2/9] $STRINGS_XML  (skip)"
        SKIPPED=$((SKIPPED+1))
    else
        echo "[2/9] $STRINGS_XML  패치"
        sed -i "s|<string name=\"app_name\">RustDesk</string>|<string name=\"app_name\">$APP_NAME_NEW</string>|" "$STRINGS_XML"
        sed -i "s|RustDesk screen sharing|$APP_NAME_NEW screen sharing|" "$STRINGS_XML"
        PATCHED=$((PATCHED+1))
    fi
fi

# ────────────────────────────────────────────────────────────
# [3/9] 어댑티브 아이콘 PNG 일괄 복사
#   - ic_launcher.png (legacy)
#   - ic_launcher_foreground.png (Android 8+ adaptive icon)
#   - ic_launcher_round.png
#   - ic_stat_logo.png (notification)
# ────────────────────────────────────────────────────────────
ICONS_SRC="overlay/icons/agent"
if [ -d "$ICONS_SRC" ]; then
    echo "[3/9] 아이콘 복사: $ICONS_SRC → mipmap-*dpi/"
    for dpi in hdpi xhdpi xxhdpi xxxhdpi; do
        SRC="$ICONS_SRC/$dpi.png"
        DST_DIR="flutter/android/app/src/main/res/mipmap-$dpi"
        if [ -f "$SRC" ] && [ -d "$DST_DIR" ]; then
            cp "$SRC" "$DST_DIR/ic_launcher.png"
            cp "$SRC" "$DST_DIR/ic_launcher_foreground.png"
            cp "$SRC" "$DST_DIR/ic_launcher_round.png"
            cp "$SRC" "$DST_DIR/ic_stat_logo.png"
            echo "    $DST_DIR  (4종 덮어씀)"
        fi
    done
    PATCHED=$((PATCHED+1))
else
    echo "[3/9] 아이콘  $ICONS_SRC 없음 (skip)"
fi

# ────────────────────────────────────────────────────────────
# [4/9] Cargo.toml — Windows EXE 메타데이터 + bundle name
# ────────────────────────────────────────────────────────────
CARGO="Cargo.toml"
if [ -f "$CARGO" ]; then
    if grep -q "ProductName = \"$APP_NAME_NEW\"" "$CARGO"; then
        echo "[4/9] $CARGO  (skip)"
        SKIPPED=$((SKIPPED+1))
    else
        echo "[4/9] $CARGO  패치"
        sed -i \
            -e "s|^ProductName = \"RustDesk\"|ProductName = \"$APP_NAME_NEW\"|" \
            -e "s|^FileDescription = \"RustDesk Remote Desktop\"|FileDescription = \"$APP_NAME_NEW Remote Desktop\"|" \
            -e "s|^OriginalFilename = \"rustdesk.exe\"|OriginalFilename = \"cuberemote.exe\"|" \
            "$CARGO"
        # [package.metadata.bundle] 섹션의 name 만 (다른 name은 건드리지 않음)
        sed -i "/\[package.metadata.bundle\]/,/^\[/ { s|^name = \"RustDesk\"|name = \"$APP_NAME_NEW\"|; }" "$CARGO"
        PATCHED=$((PATCHED+1))
    fi
fi

# ────────────────────────────────────────────────────────────
# [5/9] 한국어/영어 lang 파일 — RustDesk → CubeRemote 일괄
#   ko.rs / en.rs 모두 키와 값 동시 변환 (매칭 유지)
# ────────────────────────────────────────────────────────────
for LANG_RS in src/lang/ko.rs src/lang/en.rs; do
    if [ -f "$LANG_RS" ]; then
        if ! grep -q "RustDesk" "$LANG_RS"; then
            echo "[5/9] $LANG_RS  (skip)"
            SKIPPED=$((SKIPPED+1))
        else
            echo "[5/9] $LANG_RS  RustDesk → $APP_NAME_NEW"
            sed -i "s|RustDesk|$APP_NAME_NEW|g" "$LANG_RS"
            PATCHED=$((PATCHED+1))
        fi
    fi
done

# ────────────────────────────────────────────────────────────
# [6/9] Flutter Dart 하드코딩 + translate 키 일치
# ────────────────────────────────────────────────────────────
TABBAR="flutter/lib/desktop/widgets/tabbar_widget.dart"
if [ -f "$TABBAR" ] && grep -q '"RustDesk"' "$TABBAR"; then
    echo "[6/9] $TABBAR"
    sed -i "s|\"RustDesk\"|\"$APP_NAME_NEW\"|g" "$TABBAR"
fi

# translate('...RustDesk...') 호출들 → lang 파일과 키 매칭 유지
for DART in flutter/lib/desktop/pages/desktop_setting_page.dart \
            flutter/lib/mobile/pages/settings_page.dart; do
    if [ -f "$DART" ] && grep -q "translate('.*RustDesk" "$DART"; then
        echo "[6/9] $DART  translate 키 갱신"
        sed -i "s|translate('Keep RustDesk background service')|translate('Keep $APP_NAME_NEW background service')|g" "$DART"
        sed -i "s|translate('About RustDesk')|translate('About $APP_NAME_NEW')|g" "$DART"
    fi
done

# ────────────────────────────────────────────────────────────
# [7/9] Kotlin 알림/Toast/메뉴 문자열
# ────────────────────────────────────────────────────────────
KOT_DIR="flutter/android/app/src/main/kotlin/com/cube/cuberemote"
if [ -d "$KOT_DIR" ]; then
    echo "[7/9] Kotlin 문자열"
    if [ -f "$KOT_DIR/BootReceiver.kt" ]; then
        sed -i "s|\"RustDesk is Open\"|\"$APP_NAME_NEW is Open\"|g" "$KOT_DIR/BootReceiver.kt"
    fi
    if [ -f "$KOT_DIR/MainService.kt" ]; then
        sed -i \
            -e "s|DEFAULT_NOTIFY_TITLE = \"RustDesk\"|DEFAULT_NOTIFY_TITLE = \"$APP_NAME_NEW\"|" \
            -e "s|val channelId = \"RustDesk\"|val channelId = \"$APP_NAME_NEW\"|" \
            -e "s|val channelName = \"RustDesk Service\"|val channelName = \"$APP_NAME_NEW Service\"|" \
            -e "s|description = \"RustDesk Service Channel\"|description = \"$APP_NAME_NEW Service Channel\"|" \
            "$KOT_DIR/MainService.kt"
    fi
fi

# ────────────────────────────────────────────────────────────
# [8/9] AndroidManifest "RustDesk Input" 접근성 서비스 라벨
# ────────────────────────────────────────────────────────────
MANIFEST="flutter/android/app/src/main/AndroidManifest.xml"
if [ -f "$MANIFEST" ] && grep -q 'android:label="RustDesk Input"' "$MANIFEST"; then
    echo "[8/9] $MANIFEST"
    sed -i "s|android:label=\"RustDesk Input\"|android:label=\"$APP_NAME_NEW Input\"|" "$MANIFEST"
fi

# ────────────────────────────────────────────────────────────
# [9/9] flutter/lib/main.dart — cuberemote 모듈 훅 주입
#   - 매장 등록 화면 (최초 실행)
#   - heartbeat 시작 (등록 완료 기기)
# ────────────────────────────────────────────────────────────
MAIN_DART="flutter/lib/main.dart"
if [ -f "$MAIN_DART" ]; then
    if grep -q "cuberemote/main_hook" "$MAIN_DART"; then
        echo "[9/9] $MAIN_DART  (skip — 훅 이미 주입됨)"
        SKIPPED=$((SKIPPED+1))
    else
        echo "[9/9] $MAIN_DART  훅 주입"
        # 1) import 추가 (common.dart import 다음 줄에)
        sed -i "/^import 'common.dart';/a import 'cuberemote/main_hook.dart';" "$MAIN_DART"
        # 2) runMobileApp() 시작 부분에 hook 호출
        sed -i "s|^void runMobileApp() async {|void runMobileApp() async {\n  await CubeRemoteMainHook.onAppStart();|" "$MAIN_DART"
        # 3) runApp(App()) → wrapApp 으로 감싸기 (등록 화면 표시)
        sed -i "s|runApp(App());|runApp(CubeRemoteMainHook.wrapApp(App()));|" "$MAIN_DART"
        PATCHED=$((PATCHED+1))
    fi
fi

# ────────────────────────────────────────────────────────────
# 검증
# ────────────────────────────────────────────────────────────
echo ""
echo "=== 패치 결과: $PATCHED 적용 / $SKIPPED 스킵 ==="
echo ""
echo "=== 검증 ==="

check() {
    local label="$1" file="$2" pattern="$3"
    if [ -f "$file" ] && grep -q "$pattern" "$file"; then
        echo "  ✓ $label"
    else
        echo "  ✗ $label  ($file)"
        FAIL=1
    fi
}

FAIL=0
check "서버 주소"     "$CONFIG_RS"   "\"$RDV_SERVER\""
check "공개키"         "$CONFIG_RS"   "\"$PUB_KEY\""
check "APP_NAME"       "$CONFIG_RS"   "RwLock::new(\"$APP_NAME_NEW\""
check "Android app_name" "$STRINGS_XML" ">$APP_NAME_NEW<"
check "main.dart 훅"   "$MAIN_DART"   "cuberemote/main_hook"
check "Cargo winres"   "$CARGO"       "ProductName = \"$APP_NAME_NEW\""

if [ "$FAIL" = "1" ]; then
    echo ""
    echo "=== [FATAL] 일부 패치가 적용되지 않았습니다 ==="
    exit 1
fi

echo ""
echo "=== 모든 브랜딩 패치 완료 ==="
