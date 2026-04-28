// CubeRemote 서버 설정 (apply.sh 가 API_BASE / FLAVOR / AGENT_VERSION 을 빌드 시 주입)
library cuberemote_config;

const API_BASE = "https://remote.cube-tech.co.kr/api/cuberemote";
const HEARTBEAT_INTERVAL_SECONDS = 60;
const AGENT_VERSION = "1.0.0";

// 빌드 flavor: agent (POS) / viewer (관리자) / support (1회용 고객 지원)
const FLAVOR = String.fromEnvironment("CUBE_FLAVOR", defaultValue: "agent");

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
