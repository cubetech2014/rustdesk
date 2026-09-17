// CubeRemote 서버 설정 (apply.sh 가 API_BASE / FLAVOR / AGENT_VERSION / ABI 를 빌드 시 주입)
library cuberemote_config;

const API_BASE = "https://remote.cube-tech.co.kr/api/cuberemote";
const HEARTBEAT_INTERVAL_SECONDS = 60;
const AGENT_VERSION = "1.0.0";

// 빌드 flavor: agent (POS) / viewer (관리자) / support (1회용 고객 지원)
const FLAVOR = String.fromEnvironment("CUBE_FLAVOR", defaultValue: "agent");

// 빌드 대상 CPU 아키텍처 — apply.sh 가 CUBE_ABI env 로 hardcode.
//   Android: arm64 / armv7,  Windows: x64 / x86
// 자동 업데이트 조회 시 서버가 같은 arch 의 설치 파일 URL 을 주도록 하는 키.
// 이게 없으면 32비트 기기가 arm64 APK 를 받아 "앱이 설치되지 않았습니다" 로 끝남.
// 빈 문자열이면 arch 를 안 보냄 → 서버가 플랫폼 기본값 (Android=arm64 / Windows=x64)
// 으로 처리. v1.0.40 이하 배포본과 동일한 동작이라 하위호환 유지됨.
const ABI = "";

bool get isAgentFlavor   => FLAVOR == "agent";
bool get isViewerFlavor  => FLAVOR == "viewer";
bool get isSupportFlavor => FLAVOR == "support";

// SharedPreferences 키 — agent 등록 정보
const PREF_SHOP_ID   = "cuberemote_shop_id";
const PREF_P_ID      = "cuberemote_p_id";
const PREF_H_ID      = "cuberemote_h_id";
const PREF_SHOP_NM   = "cuberemote_shop_nm";
const PREF_DEVICE_NM = "cuberemote_device_nm";

// SharedPreferences 키 — viewer 토큰 세션
const PREF_SESSION_TOKEN  = "cuberemote_session_token";
const PREF_SESSION_USER   = "cuberemote_session_user";   // JSON {id, name, role, p_id, p_nm}
const PREF_DEVICE_FP      = "cuberemote_device_fp";      // 기기 식별자 (UUID, 1회 생성)

// viewer 세션 ping 주기 (초). 30분 무활동 만료에 충분히 못 미쳐야 함.
const SESSION_PING_INTERVAL_SECONDS = 60;
