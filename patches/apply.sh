#!/bin/bash
# CubeRemote 통합 빌드 패치
# CI에서 submodule init 후 / cargo, flutter build 전에 실행
# Idempotent: 이미 패치된 항목은 자동 스킵

set -e

echo "=== CubeRemote 통합 빌드 패치 시작 ==="

# === 설정 ===
RDV_SERVER="203.245.29.78"
PUB_KEY="i3sWZx4sShCLVGZ3mPoZVbzeYfc7VK1pOy2XdrRhkt0="

# === Flavor 분기 (CUBE_FLAVOR=agent|viewer, default agent) ===
FLAVOR="${CUBE_FLAVOR:-agent}"
case "$FLAVOR" in
    viewer)
        APP_NAME_NEW="CubeRemote Viewer"
        ANDROID_LABEL="CubeRemote 관리자"
        HARD_CONN_TYPE="outgoing"
        ;;
    *)
        APP_NAME_NEW="CubeRemote"
        ANDROID_LABEL="CubeRemote"
        HARD_CONN_TYPE="incoming"
        ;;
esac
echo "FLAVOR=$FLAVOR  APP_NAME=$APP_NAME_NEW  conn-type=$HARD_CONN_TYPE"

# === config.dart FLAVOR + AGENT_VERSION 빌드 시점 hardcode ===
# (dart-define 대신 직접 sed — Windows build.py 가 인자 통과 안 시켜서 일관성 위해)
CUBE_TAG_VAL="${CUBE_TAG:-dev}"
CONFIG_DART="flutter/lib/cuberemote/config.dart"
if [ -f "$CONFIG_DART" ]; then
    sed -i "s|^const AGENT_VERSION = .*|const AGENT_VERSION = \"$CUBE_TAG_VAL\";|" "$CONFIG_DART"
    sed -i "s|^const FLAVOR = .*|const FLAVOR = \"$FLAVOR\";|" "$CONFIG_DART"
    echo "AGENT_VERSION=$CUBE_TAG_VAL  FLAVOR=$FLAVOR (hardcoded into config.dart)"
fi

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
        # APP_NAME 라인 한정 — 어떤 값이든 새 flavor 값으로 교체
        sed -e "/pub static ref APP_NAME/ s|RwLock::new(\"[^\"]*\".to_owned())|RwLock::new(\"$APP_NAME_NEW\".to_owned())|" \
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
    if grep -q "name=\"app_name\">$ANDROID_LABEL<" "$STRINGS_XML"; then
        echo "[2/9] $STRINGS_XML  (skip)"
        SKIPPED=$((SKIPPED+1))
    else
        echo "[2/9] $STRINGS_XML  패치 (label=$ANDROID_LABEL)"
        # 기존 어떤 값이든 새 라벨로 교체
        sed -i "s|<string name=\"app_name\">[^<]*</string>|<string name=\"app_name\">$ANDROID_LABEL</string>|" "$STRINGS_XML"
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
ICONS_SRC="overlay/icons/$FLAVOR"
if [ -d "$ICONS_SRC" ]; then
    echo "[3/9] 아이콘 복사: $ICONS_SRC → mipmap-*dpi/ (flavor=$FLAVOR)"
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
            -e "s|^ProductName = \"[^\"]*\"|ProductName = \"$APP_NAME_NEW\"|" \
            -e "s|^FileDescription = \"[^\"]*\"|FileDescription = \"$APP_NAME_NEW Remote Desktop\"|" \
            -e "s|^OriginalFilename = \"[^\"]*\"|OriginalFilename = \"cuberemote-${FLAVOR}.exe\"|" \
            "$CARGO"
        # [package.metadata.bundle] 섹션의 name 만 (다른 name은 건드리지 않음)
        sed -i "/\[package.metadata.bundle\]/,/^\[/ { s|^name = \"[^\"]*\"|name = \"$APP_NAME_NEW\"|; }" "$CARGO"
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
# [10/11] flutter_ffi.rs initialize() — incoming-only 모드 강제
#   → ConnectionPage 자동 제거 (POS는 원격 제어 받기만)
#   home_page.dart 의 `if (!bind.isIncomingOnly())` 분기로 자동 적용
# ────────────────────────────────────────────────────────────
FFI_RS="src/flutter_ffi.rs"
if [ -f "$FFI_RS" ]; then
    if grep -q "CubeRemote: force conn-type=$HARD_CONN_TYPE" "$FFI_RS"; then
        echo "[10/11] $FFI_RS  (skip — flavor=$FLAVOR conn-type=$HARD_CONN_TYPE 이미 주입)"
    else
        echo "[10/11] $FFI_RS  conn-type=$HARD_CONN_TYPE 강제 주입"
        # 기존 CubeRemote 주입 라인이 있으면 먼저 제거 (다른 flavor 일 수 있음)
        sed -i '/CubeRemote: force conn-type/d' "$FFI_RS"
        sed -i '/HARD_SETTINGS.write().unwrap().insert("conn-type"/d' "$FFI_RS"
        sed -i "/^fn initialize(app_dir: &str, custom_client_config: &str) {/a\\    // CubeRemote: force conn-type=$HARD_CONN_TYPE\\n    config::HARD_SETTINGS.write().unwrap().insert(\"conn-type\".to_string(), \"$HARD_CONN_TYPE\".to_string());" "$FFI_RS"
    fi
fi

# ────────────────────────────────────────────────────────────
# [10b] mobile/pages/home_page.dart — 채팅 탭 제거 (POS 는 채팅 안 씀)
# ────────────────────────────────────────────────────────────
HOME_DART="flutter/lib/mobile/pages/home_page.dart"
if [ -f "$HOME_DART" ]; then
    if grep -q "// CubeRemote: ChatPage removed" "$HOME_DART"; then
        echo "[10b] $HOME_DART  (skip — 이미 패치)"
    else
        echo "[10b] $HOME_DART  채팅 탭 제거"
        sed -i 's|_pages.addAll(\[ChatPage(type: ChatPageType.mobileMain), ServerPage()\]);|_pages.add(ServerPage()); // CubeRemote: ChatPage removed|' "$HOME_DART"
    fi
fi

# ────────────────────────────────────────────────────────────
# [11/11] settings_page.dart — CubeRemote 섹션 추가 (장비 등록 / 재등록)
# ────────────────────────────────────────────────────────────
SETTINGS_DART="flutter/lib/mobile/pages/settings_page.dart"
if [ -f "$SETTINGS_DART" ]; then
    if grep -q "cuberemote/settings_tile" "$SETTINGS_DART"; then
        echo "[11/11] $SETTINGS_DART  (skip — 이미 주입됨)"
    else
        echo "[11/11] $SETTINGS_DART  CubeRemote 설정 메뉴 주입"
        # import 추가 (settings_ui import 다음 라인에)
        sed -i "/^import 'package:settings_ui\/settings_ui.dart';/a import '../../cuberemote/settings_tile.dart';" "$SETTINGS_DART"
        # customClientSection 다음에 우리 섹션 한 줄 삽입
        sed -i 's|^        customClientSection,$|        customClientSection,\n        CubeRemoteSettingsSection.build(context),|' "$SETTINGS_DART"
    fi
fi

# ────────────────────────────────────────────────────────────
# [11b] MainActivity.kt — CubeRemoteInstaller (자동 업데이트 PackageInstaller) 등록
# ────────────────────────────────────────────────────────────
MAIN_ACTIVITY="flutter/android/app/src/main/kotlin/com/cube/cuberemote/MainActivity.kt"
if [ -f "$MAIN_ACTIVITY" ]; then
    if grep -q "CubeRemoteInstaller.register" "$MAIN_ACTIVITY"; then
        echo "[11b] $MAIN_ACTIVITY  (skip — installer 등록 이미)"
    else
        echo "[11b] $MAIN_ACTIVITY  installer 등록 주입"
        # initFlutterChannel 호출 다음 줄에 register 호출 추가
        sed -i '/initFlutterChannel(flutterMethodChannel!!)/a\        CubeRemoteInstaller.register(flutterEngine, this)' "$MAIN_ACTIVITY"
    fi
fi

# ────────────────────────────────────────────────────────────
# [11c] AndroidManifest.xml — FileProvider 추가 (자동 업데이트 APK 공유용)
# ────────────────────────────────────────────────────────────
if [ -f "$MANIFEST" ]; then
    if grep -q 'cuberemote.fileProvider' "$MANIFEST"; then
        echo "[11c] $MANIFEST  (skip — FileProvider 이미)"
    else
        echo "[11c] $MANIFEST  FileProvider 주입"
        # </application> 직전에 provider 삽입
        sed -i 's|</application>|        <provider\n            android:name="androidx.core.content.FileProvider"\n            android:authorities="${applicationId}.fileProvider"\n            android:exported="false"\n            android:grantUriPermissions="true">\n            <meta-data\n                android:name="android.support.FILE_PROVIDER_PATHS"\n                android:resource="@xml/cuberemote_file_paths" />\n        </provider>\n    </application>|' "$MANIFEST"
    fi
fi

# ────────────────────────────────────────────────────────────
# [12] settings_page.dart — 운영 무관 RustDesk 항목 hide
#   - Account 섹션 (RustDesk 클라우드 로그인)
#   - About 섹션 (Version+rustdesk.com, Privacy Statement, Build Date, Fingerprint)
#   - Directory (비디오 저장 경로)
#   - ID/Relay Server (brand 빌드 자동 설정 — 사용자 변경 차단)
# ────────────────────────────────────────────────────────────
if [ -f "$SETTINGS_DART" ]; then
    if grep -q "// CubeRemote: hidden RustDesk sections" "$SETTINGS_DART"; then
        echo "[12] $SETTINGS_DART  (skip — 항목 hide 이미 적용)"
    else
        echo "[12] $SETTINGS_DART  운영 무관 항목 hide"
        # marker 추가 (idempotent)
        sed -i "1i // CubeRemote: hidden RustDesk sections" "$SETTINGS_DART"
        # Account 섹션: bind.isDisableAccount() 호출을 강제 true (조건 false → 섹션 dead)
        sed -i 's|if (!bind.isDisableAccount())|if (false)|g' "$SETTINGS_DART"
        # About 섹션: privacy_tip marker 까지 통째로 dead
        perl -i -0pe 's|(\s+)SettingsSection\(\s*title: Text\(translate\("About"\)\),[\s\S]*?Icons\.privacy_tip\),\s*\)\s*\],\s*\),|$1// CubeRemote: About hidden|s' "$SETTINGS_DART"
        # Directory tile (비디오 저장 경로)
        perl -i -0pe 's|\s+SettingsTile\(\s*title: Text\(translate\("Directory"\)\),\s*description: Text\(bind\.mainVideoSaveDirectory[^)]*\)\),\s*\),||s' "$SETTINGS_DART"
        # ID/Relay Server tile
        perl -i -0pe 's|\s+if \(!disabledSettings && !_hideNetwork && !_hideServer\)\s+SettingsTile\([\s\S]*?showServerSettings[\s\S]*?setState\(callback\);\s*\}\);\s*\}\),||s' "$SETTINGS_DART"
    fi
fi

# ────────────────────────────────────────────────────────────
# [13] res/msi/preprocess.py — Windows MSI 설치 마법사 브랜딩
#   본가 워크플로우는 `python preprocess.py --arp -d ...` 로 호출하면서
#   --app-name / --manufacturer 인자를 안 넘겨 default 값("RustDesk"/"PURSLANE")이
#   그대로 Includes.wxi → Strings.wxl 까지 박힘.
#   default 값 자체를 sed 로 교체하면 워크플로우 호출 변경 없이 적용됨.
#   (EXE winres 는 [4/9] Cargo.toml 에서 별도 처리, 여기는 MSI 래퍼만)
# ────────────────────────────────────────────────────────────
PREPROCESS_PY="res/msi/preprocess.py"
if [ -f "$PREPROCESS_PY" ]; then
    if grep -q "default=\"$APP_NAME_NEW\"" "$PREPROCESS_PY"; then
        echo "[13] $PREPROCESS_PY  (skip — 이미 $APP_NAME_NEW)"
        SKIPPED=$((SKIPPED+1))
    else
        echo "[13] $PREPROCESS_PY  MSI installer 브랜딩 (app-name=$APP_NAME_NEW, manufacturer=CubeTech)"
        sed -i \
            -e "s|default=\"RustDesk\"|default=\"$APP_NAME_NEW\"|" \
            -e "s|default=\"PURSLANE\"|default=\"CubeTech\"|" \
            "$PREPROCESS_PY"
        PATCHED=$((PATCHED+1))
    fi
fi

# ────────────────────────────────────────────────────────────
# [14] Windows EXE/MSI 아이콘 — res/icon.ico 덮어쓰기
#   Cargo.toml winres + res/msi/preprocess.py 가 모두 res/icon.ico 사용
#   → 한 파일 덮어쓰면 EXE 파일 속성, MSI 설치 마법사, 제어판 ARP, 시작메뉴 단축키 모두 적용
#   우선순위:
#     1. overlay/icons/windows/{flavor}.ico (수제, 멀티 사이즈)
#     2. ImageMagick 으로 overlay/icons/{flavor}/xxxhdpi.png → ICO 자동 변환
#        (GitHub Actions ubuntu/windows runner 모두 magick 사전 설치)
#     3. 둘 다 없으면 skip (RustDesk 기본 아이콘 잔존, 빌드는 안 깨짐)
# ────────────────────────────────────────────────────────────
TARGET_ICO="res/icon.ico"
PRECOOKED_ICO="overlay/icons/windows/${FLAVOR}.ico"
SOURCE_PNG="overlay/icons/${FLAVOR}/xxxhdpi.png"

if [ -f "$PRECOOKED_ICO" ]; then
    echo "[14] $TARGET_ICO  ← $PRECOOKED_ICO (수제 멀티사이즈)"
    cp "$PRECOOKED_ICO" "$TARGET_ICO"
    PATCHED=$((PATCHED+1))
elif command -v magick >/dev/null 2>&1 && [ -f "$SOURCE_PNG" ]; then
    echo "[14] $TARGET_ICO  ← $SOURCE_PNG (ImageMagick 자동 변환)"
    magick "$SOURCE_PNG" -define icon:auto-resize=256,128,96,64,48,32,16 "$TARGET_ICO"
    PATCHED=$((PATCHED+1))
else
    echo "[14] Windows 아이콘 소스 없음 — RustDesk 기본 아이콘 잔존"
    echo "    overlay/icons/windows/${FLAVOR}.ico 추가하거나 ImageMagick 설치 필요"
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
check "Android app_name" "$STRINGS_XML" ">$ANDROID_LABEL<"
check "main.dart 훅"   "$MAIN_DART"   "cuberemote/main_hook"
check "Cargo winres"   "$CARGO"       "ProductName = \"$APP_NAME_NEW\""
check "conn-type=$HARD_CONN_TYPE" "$FFI_RS" "force conn-type=$HARD_CONN_TYPE"
check "settings 메뉴"  "$SETTINGS_DART" "cuberemote/settings_tile"
check "채팅 탭 제거"   "$HOME_DART"   "ChatPage removed"
check "settings hide" "$SETTINGS_DART" "// CubeRemote: hidden RustDesk sections"
check "FLAVOR hardcode" "$CONFIG_DART" "const FLAVOR = \"$FLAVOR\";"
check "MSI installer 브랜딩" "$PREPROCESS_PY" "default=\"$APP_NAME_NEW\""

if [ "$FAIL" = "1" ]; then
    echo ""
    echo "=== [FATAL] 일부 패치가 적용되지 않았습니다 ==="
    exit 1
fi

echo ""
echo "=== 모든 브랜딩 패치 완료 ==="
